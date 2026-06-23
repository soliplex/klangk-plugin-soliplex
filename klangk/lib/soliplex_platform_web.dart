// Web implementation of the Soliplex platform boundary. Swapped in by the
// conditional export in soliplex_platform.dart when dart.library.js_interop is
// available. Preserves the original plugin behavior verbatim: localStorage
// token store + popup OAuth login (the IdP dance is mediated by the Soliplex
// backend, which redirects back to `return_to` with tokens in the query).
import 'dart:async';

import 'package:klangk_plugin_api/klangk_plugin_api.dart' show baseUrl;
import 'package:web/web.dart' as web;

import 'soliplex_auth_result.dart';

/// On web the Klangk backend is same-origin; [baseUrl] is the (possibly empty)
/// path prefix the app is served under.
String soliplexBackendBase() => baseUrl;

/// localStorage-backed token store. Reads are synchronous but presented as
/// Futures so callers share one surface with the native (Keychain) store.
class SoliplexTokenStore {
  /// [namespace] isolates one server's tokens from another's: every key is
  /// prefixed with it, so multi-server deployments keep independent auth.
  /// Defaults to 'default' (the server resolved from the klangk backend
  /// config), matching the single-server history.
  SoliplexTokenStore({this.namespace = 'default'});

  final String namespace;

  String get _accessKey => 'soliplex_${namespace}_access_token';
  String get _refreshKey => 'soliplex_${namespace}_refresh_token';
  String get _expiresKey => 'soliplex_${namespace}_expires_at';
  String get _serverKey => 'soliplex_${namespace}_server_url';
  String get _clientKey => 'soliplex_${namespace}_client_id';

  web.Storage get _ls => web.window.localStorage;

  Future<String?> get accessToken async => _ls.getItem(_accessKey);
  Future<String?> get refreshToken async => _ls.getItem(_refreshKey);
  Future<String?> get serverUrl async => _ls.getItem(_serverKey);
  Future<String?> get clientId async => _ls.getItem(_clientKey);

  Future<DateTime?> get expiresAt async {
    final v = _ls.getItem(_expiresKey);
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> writeTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) async {
    _ls.setItem(_accessKey, accessToken);
    if (refreshToken != null) _ls.setItem(_refreshKey, refreshToken);
    if (expiresAt != null) {
      _ls.setItem(_expiresKey, expiresAt.toIso8601String());
    }
  }

  Future<void> writeProvider({String? serverUrl, String? clientId}) async {
    if (serverUrl != null) _ls.setItem(_serverKey, serverUrl);
    if (clientId != null) _ls.setItem(_clientKey, clientId);
  }

  Future<void> clear() async {
    _ls.removeItem(_accessKey);
    _ls.removeItem(_refreshKey);
    _ls.removeItem(_expiresKey);
    _ls.removeItem(_serverKey);
    _ls.removeItem(_clientKey);
  }
}

/// Global (non-namespaced) store for the plugin's server registry: the list of
/// servers the user (Flutter overlay) or agent (pi `soliplex_add_server`) has
/// added, persisted as a JSON string so they survive reloads. Distinct from the
/// per-server [SoliplexTokenStore] — this holds the *set* of servers, not auth.
class SoliplexConfigStore {
  static const _serversKey = 'soliplex_servers';

  web.Storage get _ls => web.window.localStorage;

  Future<String?> readServersJson() async => _ls.getItem(_serversKey);

  Future<void> writeServersJson(String json) async =>
      _ls.setItem(_serversKey, json);
}

/// Popup OIDC login. Must be called from a user gesture to avoid popup
/// blockers. Opens `$soliplexUrl/api/login/$systemId?return_to=...`, polls the
/// popup URL for the token query params once it redirects back to our origin.
Future<SoliplexAuthResult> soliplexInteractiveLogin({
  required String systemId,
  required String soliplexUrl,
  required Map<String, dynamic> systems,
  required SoliplexTokenStore store,
}) async {
  final systemData = systems[systemId] as Map<String, dynamic>?;
  if (systemData == null) {
    throw Exception('Auth system "$systemId" not found');
  }
  await store.writeProvider(
    serverUrl: systemData['server_url'] as String?,
    clientId: systemData['client_id'] as String?,
  );

  // Absolute callback on the Klangk app's OWN origin. Klangk and the Soliplex
  // server are separate origins, so a relative return_to (e.g.
  // "/soliplex-auth-callback") resolves against the Soliplex domain — the token
  // lands on the Soliplex frontend and never returns to this popup, and the
  // cross-origin popup.location.href read below throws. Sending return_to to
  // our origin makes the popup land here, same-origin, so the poller can read
  // `token=`. NOTE: the Soliplex server must allow this return_to origin.
  final callbackPath = Uri.encodeComponent(
      '${web.window.location.origin}${baseUrl}#/soliplex-auth-callback');
  final loginUrl = '$soliplexUrl/api/login/$systemId?return_to=$callbackPath';
  final popup = web.window
      .open(loginUrl, 'soliplex_auth', 'width=500,height=600,popup=yes');

  final completer = Completer<SoliplexAuthResult>();

  final timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
    try {
      if (popup == null || popup.closed) {
        t.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
              Exception('Auth popup was closed before completing'));
        }
        return;
      }
      final href = popup.location.href;
      if (href.contains('token=')) {
        t.cancel();
        popup.close();
        final uri = Uri.parse(href);
        final token = uri.queryParameters['token'];
        final refreshToken = uri.queryParameters['refresh_token'];
        final expiresIn = uri.queryParameters['expires_in'];
        if (token == null || token.isEmpty) {
          completer
              .completeError(Exception('No token in auth callback'));
          return;
        }
        final expiresAt = expiresIn != null
            ? DateTime.now().add(Duration(seconds: int.parse(expiresIn)))
            : null;
        store.writeTokens(
          accessToken: token,
          refreshToken: refreshToken,
          expiresAt: expiresAt,
        );
        completer.complete(SoliplexAuthResult(
          accessToken: token,
          refreshToken: refreshToken,
          expiresAt: expiresAt,
        ));
      }
    } catch (_) {
      // Cross-origin access to popup.location throws — keep polling.
    }
  });

  Future.delayed(const Duration(minutes: 2), () {
    if (!completer.isCompleted) {
      timer.cancel();
      try {
        popup?.close();
      } catch (_) {}
      completer
          .completeError(Exception('Auth popup timed out after 2 minutes'));
    }
  });

  return completer.future;
}
