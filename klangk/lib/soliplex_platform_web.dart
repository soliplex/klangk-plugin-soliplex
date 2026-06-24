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
/// blockers. Opens `$soliplexUrl/api/login/$systemId?return_to=...`, polls the
/// popup URL for the token query params once it redirects back to our origin.
Future<SoliplexAuthResult> soliplexInteractiveLogin({
  required String systemId,
  required String soliplexUrl,
  required Map<String, dynamic> systems,
  required SoliplexTokenStore store,
}) async {
  // Compute the login URL synchronously (no awaits: soliplexUrl/systemId
  // are params; baseUrl reads the <base> DOM tag synchronously) so we can
  // open the popup directly to it.
  final callbackPath =
      Uri.encodeComponent('${web.window.location.origin}${baseUrl}/health');
  final loginUrl = '$soliplexUrl/api/login/$systemId?return_to=$callbackPath';

  // Open the popup DIRECTLY to the login URL — NOT about:blank + a later
  // location.replace(). Navigating a popup cross-origin via location.replace
  // SEVERS the opener's handle in Firefox: popup.location reads then throw
  // SecurityError forever, even after the popup navigates back same-origin to
  // /health, so the poller can never read the token (2-min timeout). Opening
  // the real URL directly preserves the handle across the cross-origin IdP
  // round trip — the poller reads token= once the popup returns. The feature
  // string (width/height + popup=yes) marks it a 'requested popup', so Firefox
  // permits it even though this runs several awaits deep from the Connect tap
  // (verified: not blocked, handle stays readable, both Chrome + Firefox 150).
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

  final timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
    // Reading popup.location.href throws a SecurityError while the popup is on
    // the IdP/Soliplex (cross-origin) pages — that's expected, keep polling.
    // Only same-origin reads (our /health callback) succeed. The try is
    // narrowed to JUST that read so a later parse/store error can't be
    // swallowed after we've already cancelled the timer + closed the popup
    // (which would leave the completer forever uncompleted → 2-min timeout).
    final String href;
    try {
      if (popup == null || popup.closed) {
        t.cancel();
        if (!completer.isCompleted) {
          print('[soliplex-auth] popup closed before completing');
          completer.completeError(
              Exception('Auth popup was closed before completing'));
        }
        return;
      }
      href = popup.location.href;
      // Logs only when the read SUCCEEDS — i.e. the popup is back on our
      // origin. Its absence means popup.location reads are throwing every
      // tick (cross-origin / isolated). Its presence shows the real URL the
      // poller sees, token or not — the key diagnostic.
      print('[soliplex-auth] same-origin read: $href');
    } catch (_) {
      return; // cross-origin — keep polling
    }

    if (!href.contains('token=') || completer.isCompleted) return;
    t.cancel();
    print('[soliplex-auth] token detected in popup URL; completing');

    final uri = Uri.parse(href);
    final token = uri.queryParameters['token'];
    final refreshToken = uri.queryParameters['refresh_token'];
    final expiresIn = uri.queryParameters['expires_in'];
    if (token == null || token.isEmpty) {
      print('[soliplex-auth] ERROR: no token param (href=$href)');
      completer.completeError(Exception('No token in auth callback'));
      return;
    }
    // tryParse: a non-numeric expires_in must not throw and hang the completer.
    final expiresAtSecs = int.tryParse(expiresIn ?? '');
    final expiresAt = expiresAtSecs == null
        ? null
        : DateTime.now().add(Duration(seconds: expiresAtSecs));
    try {
      store.writeTokens(
        accessToken: token,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      );
      print('[soliplex-auth] tokens stored; '
          'expires_in=${expiresIn ?? "(none)"}');
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
  });

  Future.delayed(const Duration(minutes: 2), () {
    if (!completer.isCompleted) {
      print('[soliplex-auth] TIMEOUT after 2 min — token never reached '
          'same-origin /health (or popup.location read always threw)');
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
