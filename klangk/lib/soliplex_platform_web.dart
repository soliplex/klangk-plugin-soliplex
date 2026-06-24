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
  final systemData = systems[systemId] as Map<String, dynamic>?
      ?? const <String, dynamic>{};
  // Open the popup SYNCHRONOUSLY, before ANY await. Firefox expires "transient
  // user activation" at the first await boundary, so a window.open() run after
  // an await (this fn executes several awaits deep from the Connect tap)
  // returns null there and the popup is silently blocked. Chrome keeps
  // activation across awaits, which is why this worked on Chrome but failed on
  // Firefox. Opening a blank popup NOW — within the gesture — keeps it alive;
  // we set its location after computing the login URL. `popup=yes` + a real
  // feature string marks it as a requested popup so it is not blocked even
  // outside activation.
  final popup = web.window
      .open('about:blank', 'soliplex_auth', 'width=500,height=600,popup=yes');
  print('[soliplex-auth] opened popup (blank); '
      'handle is null: ${popup == null} (null = popup blocker)');

  await store.writeProvider(
    serverUrl: systemData['server_url'] as String?,
    clientId: systemData['client_id'] as String?,
  );

  // Absolute callback on the Klangk app's OWN origin, pointing at the backend's
  // static `${baseUrl}/health` endpoint (NOT a SPA hash route). A hash route
  // (e.g. #/soliplex-auth-callback) loads the SPA, whose GoRouter has no such
  // route and throws GoException + bounces to /login — navigating the popup
  // away from the `?token=` the poller needs. /health returns a plain JSON body
  // and just sits there, so the token query stays in popup.location.href,
  // same-origin, for the poller to read. Soliplex's auth views (authn.py)
  // pass `return_to` through verbatim with no allowlist/origin check — they
  // only construct the OAuth `redirect_uri` as their OWN callback and nest
  // return_to inside it — so no server-side allowlisting is needed.
  final callbackPath =
      Uri.encodeComponent('${web.window.location.origin}${baseUrl}/health');
  final loginUrl = '$soliplexUrl/api/login/$systemId?return_to=$callbackPath';
  print('[soliplex-auth] navigating popup; loginUrl=$loginUrl');
  if (popup == null) {
    // Popup was blocked. The gesture is gone, so surface a clear error rather
    // than hanging until the 2-min timeout.
    throw Exception(
        'Auth popup was blocked by the browser. Allow popups for this site '
        'and try again.');
  }
  popup.location.replace(loginUrl);

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
