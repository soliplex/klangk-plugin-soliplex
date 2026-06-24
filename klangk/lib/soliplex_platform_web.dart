// Web implementation of the Soliplex platform boundary. Swapped in by the
// conditional export in soliplex_platform.dart when dart.library.js_interop is
// available. Preserves the original plugin behavior verbatim: localStorage
// token store + popup OAuth login (the IdP dance is mediated by the Soliplex
// backend, which completes the flow by postMessaging the tokens back here).
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

/// Popup OIDC login. Opens `$soliplexUrl/api/login/$systemId?return_to=...`;
/// the popup runs the IdP dance on Soliplex's origin, then Soliplex's callback
/// page `postMessage`s the tokens back to this window, which we receive here.
/// (We deliberately do NOT poll `popup.location.href`: real Firefox severs the
/// opener's handle to a cross-origin-navigated popup, so that approach is not
/// portable. postMessage is.)
Future<SoliplexAuthResult> soliplexInteractiveLogin({
  required String systemId,
  required String soliplexUrl,
  required Map<String, dynamic> systems,
  required SoliplexTokenStore store,
}) async {
  // `return_to` is only used by Soliplex as the fallback redirect when there
  // is NO window.opener (e.g. the page was opened directly). In the normal
  // popup case Soliplex instead renders an HTML handshake that postMessages
  // the tokens here — so this value is just an inert fallback landing page.
  // `/health` (a static JSON endpoint on our own origin) is a safe choice.
  final callbackPath =
      Uri.encodeComponent('${web.window.location.origin}${baseUrl}/health');
  final loginUrl = '$soliplexUrl/api/login/$systemId?return_to=$callbackPath';

  // Open the popup directly to the login URL. The feature string
  // (width/height + popup=yes) marks it a 'requested popup', so Firefox
  // permits it even though this runs several awaits deep from the Connect tap
  // (verified: not blocked in Chrome or Firefox). If it is null (truly
  // blocked), surface a clear error instead of hanging.
  final popup = web.window
      .open(loginUrl, 'soliplex_auth', 'width=500,height=600,popup=yes');
  print('[soliplex-auth] opened popup; loginUrl=$loginUrl; '
      'handle is null: ${popup == null}');
  if (popup == null) {
    throw Exception(
        'Auth popup was blocked by the browser. Allow popups for this site '
        'and try again.');
  }

  final systemData = systems[systemId] as Map<String, dynamic>?
      ?? const <String, dynamic>{};
  await store.writeProvider(
    serverUrl: systemData['server_url'] as String?,
    clientId: systemData['client_id'] as String?,
  );

  final completer = Completer<SoliplexAuthResult>();

  // The popup completes the whole IdP dance on Soliplex's origin, then
  // Soliplex's callback page postMessages the tokens back to this window.
  // This replaces the old poller that read popup.location.href. That poller
  // does NOT work in real Firefox: once a popup navigates cross-origin (to the
  // IdP), Firefox severs the opener's handle — popup.location throws
  // SecurityError FOREVER, even after the popup returns same-origin — so the
  // poller never sees the token (2-min timeout). Chrome restores same-origin
  // access after the round trip; Firefox does not. postMessage is explicitly
  // designed for cross-window comms and works in every browser.
  final expectedOrigin = Uri.parse(soliplexUrl).origin;
  print('[soliplex-auth] expecting postMessage from $expectedOrigin');

  void finish(String token, String? refreshToken, int? expiresInSecs) {
    if (completer.isCompleted) return;
    final expiresAt = expiresInSecs == null
        ? null
        : DateTime.now().add(Duration(seconds: expiresInSecs));
    try {
      store.writeTokens(
        accessToken: token,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      );
      print('[soliplex-auth] tokens stored; expires_in=$expiresInSecs');
    } catch (e, st) {
      print('[soliplex-auth] ERROR storing tokens: $e\n$st');
    }
    try {
      popup.close();
    } catch (_) {}
    if (!completer.isCompleted) {
      completer.complete(SoliplexAuthResult(
        accessToken: token,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      ));
    }
  }

  // window.closed IS readable cross-origin (unlike .location), so a light
  // timer detects the user closing the popup early. It never reads the token —
  // only postMessage carries the token.
  late final Timer closeTimer;
  late final JSFunction messageHandler;

  void onMessage(web.Event event) {
    final me = event as web.MessageEvent;
    if (me.origin != expectedOrigin) {
      print('[soliplex-auth] ignored message from ${me.origin}');
      return;
    }
    final dynamic data = me.data.dartify();
    final type = data is Map ? data['type'] : null;
    print('[soliplex-auth] message from ${me.origin}: type=$type');
    if (type != 'soliplex-auth') return;
    final token = data['token'];
    if (token is! String || token.isEmpty) {
      print('[soliplex-auth] ERROR: postMessage had no token');
      if (!completer.isCompleted) {
        completer.completeError(Exception('No token in auth callback'));
      }
      return;
    }
    final refreshToken = data['refresh_token'] as String?;
    final rawExpires = data['expires_in'];
    final expiresInSecs = rawExpires is String
        ? int.tryParse(rawExpires)
        : (rawExpires is num ? rawExpires.toInt() : null);
    closeTimer.cancel();
    web.window.removeEventListener('message', messageHandler);
    finish(token, refreshToken, expiresInSecs);
  }

  messageHandler = onMessage.toJS;
  web.window.addEventListener('message', messageHandler);
  print('[soliplex-auth] registered postMessage listener');

  closeTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
    if (popup.closed) {
      t.cancel();
      web.window.removeEventListener('message', messageHandler);
      if (!completer.isCompleted) {
        print('[soliplex-auth] popup closed before completing');
        completer.completeError(
            Exception('Auth popup was closed before completing'));
      }
    }
  });

  Future.delayed(const Duration(minutes: 2), () {
    if (!completer.isCompleted) {
      print('[soliplex-auth] TIMEOUT after 2 min — no postMessage from '
          'Soliplex (expected origin $expectedOrigin)');
      closeTimer.cancel();
      web.window.removeEventListener('message', messageHandler);
      try {
        popup.close();
      } catch (_) {}
      completer
          .completeError(Exception('Auth popup timed out after 2 minutes'));
    }
  });

  return completer.future;
}
