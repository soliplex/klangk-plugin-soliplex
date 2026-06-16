import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:klangk_plugin_soliplex/soliplex_servers.dart';
import 'package:klangk_plugin_soliplex/soliplex_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

SoliplexClient clientWith(http.Client http_) => SoliplexClient(
      SoliplexServerSession(
        server: const SoliplexServer(name: 'default', baseUrl: 'https://api'),
        httpClient: http_,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SoliplexClient.listRooms', () {
    test('maps a {id: room} object into a room_id list', () async {
      final c = clientWith(MockClient((req) async {
        expect(req.url.toString(), 'https://api/api/v1/rooms');
        return _json({
          'search': {'name': 'Search', 'description': 'find things'},
        });
      }));
      final rooms = await c.listRooms();
      expect(rooms.single['room_id'], 'search');
      expect(rooms.single['name'], 'Search');
    });

    test('passes through a list response', () async {
      final c = clientWith(MockClient((req) async => _json([
            {'room_id': 'a', 'name': 'A'},
          ])));
      expect((await c.listRooms()).single['room_id'], 'a');
    });

    test('returns empty for a scalar body', () async {
      final c = clientWith(MockClient((req) async => _json(42)));
      expect(await c.listRooms(), isEmpty);
    });

    test('401 clears tokens and throws', () async {
      final c = clientWith(MockClient((req) async => http.Response('no', 401)));
      expect(c.listRooms(), throwsA(isA<Exception>()));
    });

    test('non-200 throws with status', () async {
      final c = clientWith(MockClient((req) async => http.Response('boom', 500)));
      expect(c.listRooms(),
          throwsA(isA<Exception>().having((e) => '$e', 'msg', contains('500'))));
    });
  });

  group('SoliplexClient.queryRoom failure branches', () {
    test('401 on thread creation throws', () async {
      final c = clientWith(MockClient((req) async => http.Response('no', 401)));
      expect(c.queryRoom('search', 'q'), throwsA(isA<Exception>()));
    });

    test('non-200 on thread creation throws', () async {
      final c = clientWith(MockClient((req) async => http.Response('x', 502)));
      expect(c.queryRoom('search', 'q'),
          throwsA(isA<Exception>().having((e) => '$e', 'm', contains('502'))));
    });

    test('thread created with no runs throws', () async {
      final c = clientWith(MockClient((req) async =>
          _json({'thread_id': 't1', 'runs': <String, dynamic>{}})));
      expect(c.queryRoom('search', 'q'),
          throwsA(isA<Exception>().having((e) => '$e', 'm', contains('No run'))));
    });
  });

  group('SoliplexClient.replyToThread failure branches', () {
    test('401 on run creation throws', () async {
      final c = clientWith(MockClient((req) async => http.Response('no', 401)));
      expect(c.replyToThread('search', 't1', const [], 'hi'),
          throwsA(isA<Exception>()));
    });

    test('non-200 on run creation throws', () async {
      final c = clientWith(MockClient((req) async => http.Response('x', 500)));
      expect(c.replyToThread('search', 't1', const [], 'hi'),
          throwsA(isA<Exception>().having((e) => '$e', 'm', contains('500'))));
    });

    test('missing run_id throws', () async {
      final c = clientWith(MockClient((req) async => _json({'no_run': true})));
      expect(c.replyToThread('search', 't1', const [], 'hi'),
          throwsA(isA<Exception>().having((e) => '$e', 'm', contains('run_id'))));
    });
  });
}
