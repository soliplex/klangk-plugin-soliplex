import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:soliplex_client/soliplex_client.dart' as sox;

import 'soliplex_auth_result.dart';
import 'soliplex_platform.dart';

/// Shared token store (Keychain on native, localStorage on web).
final SoliplexTokenStore _store = SoliplexTokenStore();

/// Cached Soliplex URL fetched from the Klangk backend config.
String? _soliplexUrl;

/// Cached OIDC token endpoint from discovery.
String? _tokenEndpoint;

/// Fetch the Soliplex URL from the Klangk backend config endpoint. Uses the
/// platform backend base (same-origin path on web; KLANGK_BACKEND_URL define
/// on native) so the request is absolute on every target.
Future<String> _getSoliplexUrl() async {
  if (_soliplexUrl != null) return _soliplexUrl!;
  final resp = await http.get(Uri.parse('${soliplexBackendBase()}/api/config'));
  if (resp.statusCode == 200) {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    _soliplexUrl =
        (data['soliplex_url'] as String? ?? '').replaceAll(RegExp(r'/+$'), '');
  }
  _soliplexUrl ??= '';
  return _soliplexUrl!;
}

/// Discover the OIDC token endpoint from the server_url.
Future<String?> _getTokenEndpoint(String serverUrl) async {
  if (_tokenEndpoint != null) return _tokenEndpoint;
  final url = serverUrl.replaceAll(RegExp(r'/+$'), '');
  final resp =
      await http.get(Uri.parse('$url/.well-known/openid-configuration'));
  if (resp.statusCode == 200) {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    _tokenEndpoint = data['token_endpoint'] as String?;
  }
  return _tokenEndpoint;
}

/// Try to refresh the access token using the stored refresh token.
/// Returns the new access token, or null if refresh failed.
Future<String?> _tryRefreshToken() async {
  final refreshToken = await _store.refreshToken;
  final serverUrl = await _store.serverUrl;
  final clientId = await _store.clientId;
  if (refreshToken == null || serverUrl == null || clientId == null) {
    return null;
  }

  final tokenEndpoint = await _getTokenEndpoint(serverUrl);
  if (tokenEndpoint == null) return null;

  final resp = await http.post(
    Uri.parse(tokenEndpoint),
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    },
  );
  if (resp.statusCode != 200) return null;

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final newToken = data['access_token'] as String?;
  final newRefresh = data['refresh_token'] as String?;
  final expiresIn = data['expires_in'] as int?;
  if (newToken == null) return null;

  await _store.writeTokens(
    accessToken: newToken,
    refreshToken: newRefresh,
    expiresAt: expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null,
  );
  return newToken;
}

/// Clear all stored auth state. Called on 401 responses to force
/// re-authentication via the overlay button.
Future<void> clearStoredTokens() async {
  await _store.clear();
  _tokenEndpoint = null;
}

/// Whether there is a valid (non-expired) access token.
Future<bool> hasValidToken() async {
  final stored = await _store.accessToken;
  final expiresAt = await _store.expiresAt;
  if (stored == null || stored.isEmpty || expiresAt == null) return false;
  return expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)));
}

/// Get a valid access token: cached if fresh, else silent refresh, else throw
/// (caller directs the user to the "Connect to Soliplex" overlay).
Future<String> _getAccessToken() async {
  final stored = await _store.accessToken;
  final expiresAt = await _store.expiresAt;
  if (stored != null && stored.isNotEmpty && expiresAt != null) {
    if (expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return stored;
    }
  }
  final refreshed = await _tryRefreshToken();
  if (refreshed != null) return refreshed;
  throw Exception('Not authenticated. Click "Connect to Soliplex" to log in.');
}

/// Fetch available OIDC auth systems from the Soliplex backend.
/// Returns a map of system ID to system data (title, server_url,
/// client_id, scope, ...).
Future<Map<String, dynamic>> getAuthSystems() async {
  final soliplexUrl = await _getSoliplexUrl();
  final loginResp = await http.get(Uri.parse('$soliplexUrl/api/login'));
  if (loginResp.statusCode != 200) {
    throw Exception('Failed to get auth systems: ${loginResp.statusCode}');
  }
  final systems = jsonDecode(loginResp.body) as Map<String, dynamic>;
  if (systems.isEmpty) {
    throw Exception('No OIDC auth systems configured on Soliplex');
  }
  return systems;
}

/// Perform an interactive login for [systemId] via the platform flow (popup on
/// web, system-browser PKCE on native) and persist the resulting tokens.
Future<SoliplexAuthResult> soliplexLogin(String systemId) async {
  final soliplexUrl = await _getSoliplexUrl();
  final systems = await getAuthSystems();
  return soliplexInteractiveLogin(
    systemId: systemId,
    soliplexUrl: soliplexUrl,
    systems: systems,
    store: _store,
  );
}

/// Lightweight Soliplex client that calls the Soliplex API directly.
class SoliplexClient {
  SoliplexClient();

  Future<Map<String, String>> _getHeaders() async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    try {
      final token = await _getAccessToken();
      headers['Authorization'] = 'Bearer $token';
    } catch (_) {
      // Proceed without auth — server will return 401 if required.
    }
    return headers;
  }

  /// List all rooms the user has access to.
  Future<List<Map<String, dynamic>>> listRooms() async {
    final soliplexUrl = await _getSoliplexUrl();
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('$soliplexUrl/api/v1/rooms'),
      headers: headers,
    );
    if (response.statusCode == 401) {
      await clearStoredTokens();
      throw Exception(
          'Not authenticated. Click "Connect to Soliplex" to log in.');
    }
    if (response.statusCode != 200) {
      throw Exception(
          'Failed to list rooms: ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(response.body);
    if (data is Map) {
      return data.entries.map((e) {
        final room = e.value as Map<String, dynamic>;
        return {'room_id': e.key, ...room};
      }).toList();
    }
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Query a room by creating a thread, posting a question, and collecting the
  /// streamed response. Returns the answer [text] plus the new [threadId] so a
  /// caller can continue the conversation via [replyToThread] (multi-turn).
  Future<({String text, String threadId})> queryRoom(
    String roomId,
    String question, {
    void Function(String delta)? onChunk,
  }) async {
    final soliplexUrl = await _getSoliplexUrl();
    final headers = await _getHeaders();

    final threadResp = await http.post(
      Uri.parse('$soliplexUrl/api/v1/rooms/$roomId/agui'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (threadResp.statusCode == 401) {
      await clearStoredTokens();
      throw Exception(
          'Not authenticated. Click "Connect to Soliplex" to log in.');
    }
    if (threadResp.statusCode != 200) {
      throw Exception('Failed to create thread: '
          '${threadResp.statusCode} ${threadResp.body}');
    }
    final threadData = jsonDecode(threadResp.body);
    final threadId = threadData['thread_id'] as String;

    final runs = threadData['runs'] as Map<String, dynamic>? ?? {};
    if (runs.isEmpty) {
      throw Exception('No run created for thread');
    }
    final runId = runs.keys.first;

    final text = await _streamRun(
        soliplexUrl, roomId, threadId, runId,
        [sox.UserMessage(id: _messageId(0), content: question)], onChunk);
    return (text: text, threadId: threadId);
  }

  /// Continue an existing thread: create a follow-up run on [threadId] and
  /// stream the answer. This is what makes multi-turn conversations with a
  /// soliplex room possible.
  ///
  /// [priorMessages] is the conversation so far (user/assistant turns). The
  /// AG-UI run input carries the full message list — the backend does NOT
  /// replay a thread's history into a new run on its own, so the caller must
  /// supply it for the model to see earlier turns. The new [message] is
  /// appended as the latest user turn. Returns the assistant's answer.
  Future<String> replyToThread(
    String roomId,
    String threadId,
    List<sox.Message> priorMessages,
    String message, {
    void Function(String delta)? onChunk,
  }) async {
    final soliplexUrl = await _getSoliplexUrl();
    final headers = await _getHeaders();

    // Create a new run on the existing thread: POST .../agui/{threadId}.
    final runResp = await http.post(
      Uri.parse('$soliplexUrl/api/v1/rooms/$roomId/agui/$threadId'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (runResp.statusCode == 401) {
      await clearStoredTokens();
      throw Exception(
          'Not authenticated. Click "Connect to Soliplex" to log in.');
    }
    if (runResp.statusCode != 200) {
      throw Exception('Failed to create run on thread $threadId: '
          '${runResp.statusCode} ${runResp.body}');
    }
    final runData = jsonDecode(runResp.body) as Map<String, dynamic>;
    final runId = runData['run_id'] as String?;
    if (runId == null) {
      throw Exception('No run_id returned for thread $threadId');
    }

    final messages = <sox.Message>[
      ...priorMessages,
      sox.UserMessage(id: _messageId(priorMessages.length), content: message),
    ];
    return _streamRun(
        soliplexUrl, roomId, threadId, runId, messages, onChunk);
  }

  /// Stable-ish unique message id for a run input.
  String _messageId(int index) =>
      'msg-${DateTime.now().millisecondsSinceEpoch}-$index';

  /// Stream a single AG-UI run, accumulating assistant text deltas and
  /// forwarding each to [onChunk] as it arrives. Shared by [queryRoom] and
  /// [replyToThread]. [messages] is the full conversation sent to the run.
  ///
  /// Streams via soliplex_client's AgUiStreamClient rather than hand-rolling
  /// the SSE. The transport's AuthenticatedHttpClient injects the bearer;
  /// getToken is synchronous, so pre-fetch (and refresh) once.
  Future<String> _streamRun(
    String soliplexUrl,
    String roomId,
    String threadId,
    String runId,
    List<sox.Message> messages,
    void Function(String delta)? onChunk,
  ) async {
    final token = await _getAccessToken();
    final agui = sox.AgUiStreamClient(
      httpTransport: sox.HttpTransport(
        client: sox.AuthenticatedHttpClient(sox.DartHttpClient(), () => token),
      ),
      urlBuilder: sox.UrlBuilder('$soliplexUrl/api/v1'),
    );
    try {
      final input = sox.SimpleRunAgentInput(
        threadId: threadId,
        runId: runId,
        messages: messages,
      );
      final buffer = StringBuffer();
      await for (final outcome
          in agui.runAgent('rooms/$roomId/agui/$threadId/$runId', input)) {
        // runAgent yields DecodeOutcomes; unwrap decoded events and collect
        // text deltas. DecodeFailed outcomes are skipped.
        if (outcome is sox.DecodedEvent) {
          final event = outcome.event;
          if (event is sox.TextMessageContentEvent) {
            buffer.write(event.delta);
            onChunk?.call(event.delta);
          }
        }
      }
      final text = buffer.toString();
      return text.isNotEmpty ? text : '(No response from Soliplex)';
    } finally {
      agui.close();
    }
  }
}
