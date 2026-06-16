import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:klangk_plugin_soliplex/plugin.dart';
import 'package:klangk_plugin_soliplex/soliplex_servers.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

/// A registry whose config + rooms responses are driven by a MockClient.
SoliplexServerRegistry registryWith(
        http.Response Function(http.Request req) handler) =>
    SoliplexServerRegistry(httpClient: MockClient((r) async => handler(r)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  http.Response defaultRoutes(http.Request req) {
    if (req.url.path.endsWith('/api/config')) {
      return _json({'soliplex_url': 'https://api'});
    }
    if (req.url.path.endsWith('/api/v1/rooms')) {
      return _json({
        'search': {'name': 'Search', 'description': 'find things'},
      });
    }
    return http.Response('unexpected ${req.url}', 404);
  }

  group('soliplex_list_rooms', () {
    test('formats rooms under a server header (default server)', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      final out = await plugin.handlers['soliplex_list_rooms']!({});
      expect(out, contains('Rooms on "default"'));
      expect(out, contains('- search: Search — find things'));
    });

    test('names other configured servers in the header', () async {
      final reg = registryWith(defaultRoutes);
      await reg.addServer('staging', 'https://staging');
      final plugin = SoliplexPlugin(registry: reg);
      final out = await plugin.handlers['soliplex_list_rooms']!({});
      expect(out, contains('other servers: staging'));
    });

    test('empty room set reports none', () async {
      final plugin = SoliplexPlugin(registry: registryWith((req) {
        if (req.url.path.endsWith('/api/config')) {
          return _json({'soliplex_url': 'https://api'});
        }
        return _json({}); // no rooms
      }));
      final out = await plugin.handlers['soliplex_list_rooms']!({});
      expect(out, contains('No rooms available.'));
    });

    test('unknown server name yields a clear error', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      final out =
          await plugin.handlers['soliplex_list_rooms']!({'server': 'ghost'});
      expect(out, contains('Error listing rooms on "ghost"'));
      expect(out, contains('Unknown soliplex server'));
    });
  });

  group('argument validation (returns before any network)', () {
    test('soliplex_query requires a question', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(await plugin.handlers['soliplex_query']!({'room_id': 'search'}),
          'Error: question is required');
    });

    test('soliplex_reply requires thread_id then message', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(await plugin.handlers['soliplex_reply']!({'message': 'hi'}),
          'Error: thread_id is required');
      expect(
          await plugin.handlers['soliplex_reply']!(
              {'thread_id': 't1', 'message': ''}),
          'Error: message is required');
    });
  });

  group('server management tools (pi)', () {
    test('soliplex_add_server registers + lists; validates input', () async {
      SharedPreferences.setMockInitialValues({});
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));

      expect(await plugin.handlers['soliplex_add_server']!({'url': 'https://x'}),
          'Error: name is required');
      expect(
          await plugin.handlers['soliplex_add_server']!({'name': 'staging'}),
          'Error: url is required');
      expect(
          await plugin.handlers['soliplex_add_server']!(
              {'name': 'default', 'url': 'https://x'}),
          contains('reserved'));

      final added = await plugin.handlers['soliplex_add_server']!(
          {'name': 'staging', 'url': 'https://staging.example/'});
      expect(added, contains('Added soliplex server "staging"'));

      final listed = await plugin.handlers['soliplex_list_servers']!({});
      expect(listed, contains('- staging: https://staging.example'));
      expect(listed, contains('- default:'));
    });
  });

  group('streaming handlers are registered for query and reply', () {
    test('streamingHandlers expose query, query_all + reply', () {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(plugin.streamingHandlers.keys,
          containsAll(['soliplex_query', 'soliplex_query_all', 'soliplex_reply']));
    });
  });

  // Fan-out orchestration. We exercise everything UP TO the live SSE
  // (`_streamRun`, coverage-ignored): target expansion (incl. `*`), default
  // server fill-in, per-target error capture, and aggregation/formatting. We
  // drive failures through the agui thread-creation endpoint
  // (POST /api/v1/rooms/<room>/agui) returning non-200 / no-runs, which makes
  // queryRoom throw BEFORE _streamRun — so a succeeding target's happy path is
  // tested via the pure formatter, and the failing target via the real handler.
  group('soliplex_query_all validation (returns before any network)', () {
    test('requires a question', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(
          await plugin.handlers['soliplex_query_all']!({
            'targets': [
              {'room': 'search'}
            ]
          }),
          'Error: question is required');
    });

    test('requires at least one target', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(
          await plugin.handlers['soliplex_query_all']!(
              {'question': 'q', 'targets': <dynamic>[]}),
          contains('at least one target'));
      expect(
          await plugin.handlers['soliplex_query_all']!({'question': 'q'}),
          contains('at least one target'));
    });

    test('each target requires a room', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(
          await plugin.handlers['soliplex_query_all']!({
            'question': 'q',
            'targets': [
              {'server': 'default'}
            ]
          }),
          contains('requires a "room"'));
    });
  });

  group('soliplex_query_all target expansion + default fill-in', () {
    test('room "*" expands to all rooms on the server', () async {
      // defaultRoutes serves one room ("search") at /api/v1/rooms; the agui
      // POST returns no runs so the (resolved) target fails fast — but the
      // failure header proves the wildcard resolved "search" on "default".
      final plugin = SoliplexPlugin(registry: registryWith((req) {
        if (req.url.path.endsWith('/api/config')) {
          return _json({'soliplex_url': 'https://api'});
        }
        if (req.url.path.endsWith('/api/v1/rooms')) {
          return _json({
            'alpha': {'name': 'Alpha'},
            'beta': {'name': 'Beta'},
          });
        }
        // agui thread creation: no runs -> queryRoom throws before _streamRun.
        return _json({'thread_id': 't', 'runs': <String, dynamic>{}});
      }));
      final out = await plugin.handlers['soliplex_query_all']!({
        'question': 'q',
        'targets': [
          {'room': '*'}
        ]
      });
      expect(out, contains('## default/alpha'));
      expect(out, contains('## default/beta'));
      expect(out, contains('Asked 2 target(s)'));
    });

    test('omitted server fills in the default server name', () async {
      final plugin = SoliplexPlugin(registry: registryWith((req) {
        if (req.url.path.endsWith('/api/config')) {
          return _json({'soliplex_url': 'https://api'});
        }
        return _json({'thread_id': 't', 'runs': <String, dynamic>{}});
      }));
      final out = await plugin.handlers['soliplex_query_all']!({
        'question': 'q',
        'targets': [
          {'room': 'search'}
        ]
      });
      expect(out, contains('## default/search'));
    });

    test('"*" against an unknown server surfaces an expansion error', () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      final out = await plugin.handlers['soliplex_query_all']!({
        'question': 'q',
        'targets': [
          {'server': 'ghost', 'room': '*'}
        ]
      });
      expect(out, contains('Error expanding targets'));
      expect(out, contains('Unknown soliplex server'));
    });
  });

  group('soliplex_query_all partial-failure aggregation', () {
    test('one target fails, the others still report (per-target errors)',
        () async {
      // Two named servers. "default" agui POST 401s -> error entry; "good" agui
      // POST returns no-runs -> a distinct error entry. Both are captured; the
      // batch does not throw, and each target gets its own labeled section.
      final reg = registryWith((req) {
        if (req.url.path.endsWith('/api/config')) {
          return _json({'soliplex_url': 'https://api'});
        }
        // host distinguishes the two servers (default=api, good=good)
        if (req.url.host == 'good') {
          return _json({'thread_id': 't', 'runs': <String, dynamic>{}});
        }
        return http.Response('nope', 401); // default server: auth failure
      });
      await reg.addServer('good', 'https://good');
      final plugin = SoliplexPlugin(registry: reg);

      final out = await plugin.handlers['soliplex_query_all']!({
        'question': 'compare',
        'targets': [
          {'room': 'search'}, // default -> 401
          {'server': 'good', 'room': 'kb'}, // good -> no runs
        ]
      });
      expect(out, contains('Asked 2 target(s): "compare"'));
      expect(out, contains('## default/search\nError:'));
      expect(out, contains('## good/kb\nError:'));
      // partial-failure tolerant: a thrown per-target error never aborts.
    });

    test('unknown per-target server becomes a per-target error, not a throw',
        () async {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      final out = await plugin.handlers['soliplex_query_all']!({
        'question': 'q',
        'targets': [
          {'server': 'ghost', 'room': 'kb'}
        ]
      });
      expect(out, contains('## ghost/kb\nError:'));
      expect(out, contains('Unknown soliplex server'));
    });
  });

  // The pure aggregator: tests the happy-path formatting (label + the answer's
  // own Sources block + a continuation thread_id) and a mixed success/failure
  // batch, WITHOUT the live SSE. This is the boundary the handler can't reach
  // through the mock (a real answer needs _streamRun, coverage-ignored), so we
  // unit-test the formatter directly — the same approach the citations work
  // took with formatSources.
  group('formatFanOut (pure aggregator)', () {
    test('mixed batch: a success with Sources + thread_id, and a failure', () {
      final out = formatFanOut('What is RAG?', const [
        FanOutResult(
          server: 'default',
          room: 'docs',
          // queryRoom already appends its own "Sources" block to the answer;
          // formatFanOut must pass it through untouched.
          answer: 'RAG augments the LLM with retrieval.\n\nSources:\n[1] rag.md',
          threadId: 'th-1',
        ),
        FanOutResult(server: 'staging', room: 'kb', error: 'Bridge down (503)'),
      ]);
      expect(out, startsWith('Asked 2 target(s): "What is RAG?"'));
      // Success block keeps its answer + Sources and exposes the thread_id for
      // soliplex_reply continuation.
      expect(out, contains('## default/docs'));
      expect(out, contains('Sources:\n[1] rag.md'));
      expect(out, contains('thread_id: th-1'));
      expect(out, contains('soliplex_reply(server, room_id, thread_id, message)'));
      // Failure block is inline, labeled, and does not carry a thread_id.
      expect(out, contains('## staging/kb\nError: Bridge down (503)'));
    });

    test('omits the thread_id line when none is present', () {
      final out = formatFanOut('q', const [
        FanOutResult(server: 'default', room: 'docs', answer: 'ans'),
      ]);
      expect(out, contains('## default/docs\nans'));
      expect(out, isNot(contains('thread_id')));
    });
  });
}
