// Web implementation of the Soliplex platform boundary. Swapped in by the
// conditional export in soliplex_platform.dart when dart.library.js_interop is
// available. Preserves the original plugin behavior verbatim: localStorage
// token store + popup OAuth login (the IdP dance is mediated by the Soliplex
// backend, which redirects back to `return_to` with tokens in the query).
import 'dart:async';
import 'dart:js_interop';

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
  String get _openKey => 'soliplex_${namespace}_open_connected';

  web.Storage get _ls => web.window.localStorage;

  Future<String?> get accessToken async => _ls.getItem(_accessKey);
  Future<String?> get refreshToken async => _ls.getItem(_refreshKey);
  Future<String?> get serverUrl async => _ls.getItem(_serverKey);
  Future<String?> get clientId async => _ls.getItem(_clientKey);

  /// Whether this open/no-auth server has been marked connected by the user.
  /// Open servers hold no token, so this is how they show as "connected".
  Future<bool> get openConnected async => _ls.getItem(_openKey) == 'true';

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

  /// Persist (or clear) the open/no-auth "connected" marker for this server.
  Future<void> setOpenConnected(bool value) async {
    if (value) {
      _ls.setItem(_openKey, 'true');
    } else {
      _ls.removeItem(_openKey);
    }
  }

  Future<void> clear() async {
    _ls.removeItem(_accessKey);
    _ls.removeItem(_refreshKey);
    _ls.removeItem(_expiresKey);
    _ls.removeItem(_serverKey);
    _ls.removeItem(_clientKey);
    _ls.removeItem(_openKey);
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
/// blockers. Opens `$soliplexUrl/api/login/$systemId?return_to=...` and
/// receives the token back via postMessage from the callback page.
///
/// The callback page is a Flutter route (`/soliplex-auth-callback`) registered
/// by [SoliplexPlugin.routes]. It reads `?token=` from its URL and posts it
/// back to this window via `window.opener.postMessage(...)`. This works in
/// Firefox where cross-origin navigation severs the popup opener handle,
/// breaking the old polling-based approach.
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

  // Absolute callback on the Klangk app's OWN origin pointing at the Flutter
  // route registered by SoliplexPlugin.routes. The callback page reads
  // ?token= from its URL and posts it back via window.opener.postMessage().
  final callbackPath = Uri.encodeComponent(
      '${web.window.location.origin}${baseUrl}#/soliplex-auth-callback');
  final loginUrl = '$soliplexUrl/api/login/$systemId?return_to=$callbackPath';
  final popup = web.window
      .open(loginUrl, 'soliplex_auth', 'width=500,height=600,popup=yes');

  if (popup == null) {
    throw Exception(
        'Popup blocked. Please allow popups for this site and try again.');
  }

  final completer = Completer<SoliplexAuthResult>();

  // Listen for the postMessage from the callback page via EventListener.
  // Use dart:js_interop to create the listener function so it works across
  // Dart SDK versions (the `toJS` extension on plain functions is not
  // available in Dart 3.11 / Flutter 3.41).
  late final JSFunction jsListener;
  void onMessage(web.MessageEvent event) {
    // Only accept messages from our own origin.
    if (event.origin != web.window.location.origin) return;
    final data = event.data?.dartify()?.toString() ?? '';
    if (!data.contains('soliplex-auth-callback')) return;

    // Parse the key=value pairs from the message.
    final params = Uri.splitQueryString(data);
    final token = params['token'];
    if (token == null || token.isEmpty) return;

    web.window.removeEventListener('message', jsListener as web.EventListener);

    final refreshToken = params['refresh_token'];
    final expiresIn = params['expires_in'];
    final expiresAt = (expiresIn != null && expiresIn.isNotEmpty)
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

  // Wrap the Dart callback as a JS function via js_interop.
  jsListener = ((JSAny? event) {
    onMessage(event as web.MessageEvent);
  }).toJS;
  web.window.addEventListener('message', jsListener as web.EventListener);

  // Poll for popup closed (user manually closed it without completing).
  final closeTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
    if (popup.closed) {
      t.cancel();
      if (!completer.isCompleted) {
        web.window.removeEventListener(
            'message', jsListener as web.EventListener);
        completer.completeError(
            Exception('Auth popup was closed before completing'));
      }
    }
  });

  // Timeout after 2 minutes.
  Future.delayed(const Duration(minutes: 2), () {
    if (!completer.isCompleted) {
      closeTimer.cancel();
      web.window.removeEventListener(
          'message', jsListener as web.EventListener);
      try {
        popup.close();
      } catch (_) {}
      completer
          .completeError(Exception('Auth popup timed out after 2 minutes'));
    }
  });

  return completer.future;
}
