import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:soliplex_client/soliplex_client.dart' as sox;

import 'soliplex_servers.dart';

/// Asset path for the bundled default-server config (declared in pubspec
/// `flutter: assets:`). Referenced through the package prefix so it resolves
/// from the consuming klangk frontend, not just this package.
const _defaultConfigAsset =
    'packages/klangk_plugin_soliplex/assets/soliplex_config.json';

/// Read the bundled `default_url` from the plugin asset. Returns null if the
/// asset is missing or malformed (registry then falls back to legacy config).
Future<String?> _loadBundledDefaultUrl() async {
  try {
    final raw = await rootBundle.loadString(_defaultConfigAsset);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return data['default_url'] as String?;
  } catch (_) {
    return null;
  }
}

/// Process-wide registry of Soliplex servers. The plugin defaults to this one;
/// tests construct their own with an injected loader/`http.Client`.
final SoliplexServerRegistry soliplexServers =
    SoliplexServerRegistry(defaultUrlLoader: _loadBundledDefaultUrl);

/// Lightweight Soliplex API client bound to one server [session]. All requests
/// go to `session.baseUrl` with `session.headers()` (bearer when available),
/// over the session's injectable `http.Client`.
class SoliplexClient {
  SoliplexClient(this.session);

  final SoliplexServerSession session;

  http.Client get _http => session.httpClient;
  String get _baseUrl => session.baseUrl;

  Future<Never> _unauthenticated() async {
    await session.clearStoredTokens();
    throw Exception('Not authenticated. Click "Connect to Soliplex" to log in.');
  }

  /// List all rooms the user has access to on this server.
  Future<List<Map<String, dynamic>>> listRooms() async {
    final response = await _http.get(
      Uri.parse('$_baseUrl/api/v1/rooms'),
      headers: await session.headers(),
    );
    if (response.statusCode == 401) await _unauthenticated();
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
    final threadResp = await _http.post(
      Uri.parse('$_baseUrl/api/v1/rooms/$roomId/agui'),
      headers: await session.headers(),
      body: jsonEncode({}),
    );
    if (threadResp.statusCode == 401) await _unauthenticated();
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

    final text = await _streamRun(roomId, threadId, runId,
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
    // Create a new run on the existing thread: POST .../agui/{threadId}.
    final runResp = await _http.post(
      Uri.parse('$_baseUrl/api/v1/rooms/$roomId/agui/$threadId'),
      headers: await session.headers(),
      body: jsonEncode({}),
    );
    if (runResp.statusCode == 401) await _unauthenticated();
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
    return _streamRun(roomId, threadId, runId, messages, onChunk);
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
  // coverage:ignore-start
  Future<String> _streamRun(
    String roomId,
    String threadId,
    String runId,
    List<sox.Message> messages,
    void Function(String delta)? onChunk,
  ) async {
    // Auth is optional: a no-auth Soliplex deployment needs no bearer. Only
    // wrap the client with the authenticator when we actually have a token.
    String token = '';
    try {
      token = await session.getAccessToken();
    } catch (_) {
      // No token — proceed unauthenticated (no-auth server).
    }
    final inner = sox.DartHttpClient();
    final agui = sox.AgUiStreamClient(
      httpTransport: sox.HttpTransport(
        client: token.isNotEmpty
            ? sox.AuthenticatedHttpClient(inner, () => token)
            : inner,
      ),
      urlBuilder: sox.UrlBuilder('$_baseUrl/api/v1'),
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
          } else {
            // Keepalive: forward an empty chunk for every other AG-UI event
            // (run/activity/tool/thinking). The klangk bridge bounds the gap
            // BETWEEN chunks (KLANGK_BRIDGE_TIMEOUT_SECONDS, default 30s); a
            // long-but-active run (RAG + LLM, multi-step tools) emits these
            // frequently, so relaying them resets the idle timer and the
            // request never times out — even past 30s/2min. Empty deltas add
            // nothing to the answer text. (See mcdonc/klangk#82.)
            onChunk?.call('');
          }
        }
      }
      final text = buffer.toString();
      return text.isNotEmpty ? text : '(No response from Soliplex)';
    } finally {
      agui.close();
    }
  }
  // coverage:ignore-end
}
