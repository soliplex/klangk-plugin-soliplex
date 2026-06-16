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
    test('streamingHandlers expose query + reply', () {
      final plugin = SoliplexPlugin(registry: registryWith(defaultRoutes));
      expect(plugin.streamingHandlers.keys,
          containsAll(['soliplex_query', 'soliplex_reply']));
    });
  });
}
