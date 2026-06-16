import 'package:flutter/material.dart';
import 'package:klangk_plugin_api/klangk_plugin_api.dart';
import 'package:soliplex_agent/soliplex_agent.dart' show ThreadKey;
import 'package:soliplex_client/soliplex_client.dart' as sox;

import 'soliplex_servers.dart';
import 'soliplex_tools.dart';

const soliplexPluginVersion = '2026-06-04-native';

/// Knowledge-base plugin: bridges the agent's `soliplex_list_rooms` /
/// `soliplex_query` tools to the user's Soliplex server, with an auth overlay.
///
/// Platform-agnostic: all browser-only concerns (token storage, interactive
/// login) live behind soliplex_platform.dart, so this compiles for native and
/// web. No `dart:js_interop` / `package:web` imports here (Phase 4 guardrail).
class SoliplexPlugin extends ToolPlugin with ChangeNotifier {
  /// Registry of reachable Soliplex servers. Defaults to the process-wide
  /// [soliplexServers]; tests inject one backed by a mock `http.Client`.
  final SoliplexServerRegistry registry;

  bool _authenticated = false;
  bool _loggingIn = false;
  String? _loginError;

  /// In-memory conversation history per [ThreadKey] (serverId, roomId,
  /// threadId), so multi-turn [soliplex_reply] turns carry context (the AG-UI
  /// run input must include prior turns; the backend does not replay them).
  /// Keyed by the full tuple because thread ids are only unique within one
  /// room on one server. Session-scoped — cleared on reload; the thread itself
  /// persists server-side.
  final Map<ThreadKey, List<sox.Message>> _threadHistory = {};

  int _msgSeq = 0;
  String _mid(String p) => '$p-${DateTime.now().millisecondsSinceEpoch}-${_msgSeq++}';

  SoliplexPlugin({SoliplexServerRegistry? registry})
      : registry = registry ?? soliplexServers {
    _refreshAuthState();
  }

  /// Resolve the `server` tool argument to a server name, defaulting to the
  /// config-derived `default` server when absent/blank.
  String _serverArg(Map<String, dynamic> request) {
    final raw = (request['server'] as String?)?.trim();
    return (raw == null || raw.isEmpty)
        ? SoliplexServerRegistry.defaultName
        : raw;
  }

  String? get loginError => _loginError;

  Future<void> _refreshAuthState() async {
    // The collapsed icon reflects whether ANY configured server is connected.
    // Network/config failures must not throw out of the constructor's
    // fire-and-forget call.
    bool any = false;
    try {
      await registry.ensureDefault();
      for (final s in registry.servers) {
        if (await (await registry.session(s.name)).hasValidToken()) {
          any = true;
          break;
        }
      }
    } catch (_) {
      any = false;
    }
    if (any != _authenticated) {
      _authenticated = any;
      notifyListeners();
    }
  }

  /// Configured servers (ensures `default` is loaded first). For the overlay.
  Future<List<SoliplexServer>> listServers() async {
    await registry.ensureDefault();
    return registry.servers;
  }

  /// Whether [server] currently holds a valid token. For the overlay's
  /// per-server status.
  Future<bool> isServerConnected(String server) async {
    try {
      return (await registry.session(server)).hasValidToken();
    } catch (_) {
      return false;
    }
  }

  /// Add a server from the overlay UI (mirrors the pi `soliplex_add_server`
  /// path). Returns null on success or an error message.
  Future<String?> addServerFromUi(String name, String url) async {
    final n = name.trim();
    final u = url.trim();
    if (n.isEmpty) return 'Name is required';
    if (u.isEmpty) return 'URL is required';
    if (n == SoliplexServerRegistry.defaultName) {
      return '"${SoliplexServerRegistry.defaultName}" is reserved';
    }
    try {
      await registry.addServer(n, u);
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  bool get authenticated => _authenticated;
  bool get loggingIn => _loggingIn;

  /// OIDC auth systems available on [server] (for the connect overlay).
  Future<Map<String, dynamic>> getAuthSystems(
          {String server = SoliplexServerRegistry.defaultName}) async =>
      (await registry.session(server)).getAuthSystems();

  @override
  Map<String, ToolHandler> get handlers => {
        'soliplex_list_rooms': _listRooms,
        'soliplex_query': _query,
        'soliplex_reply': _reply,
        'soliplex_list_servers': _listServers,
        'soliplex_add_server': _addServer,
      };

  @override
  Map<String, StreamingToolHandler> get streamingHandlers => {
        'soliplex_query': _queryStream,
        'soliplex_reply': _replyStream,
      };

  late final _overlay = _SoliplexAuthOverlay(
    key: const ValueKey('soliplex_auth_overlay'),
    plugin: this,
  );

  @override
  Widget? buildOverlay(BuildContext context) => _overlay;

  Future<void> login(String systemId,
      {String server = SoliplexServerRegistry.defaultName}) async {
    _loggingIn = true;
    _loginError = null;
    notifyListeners();
    try {
      await (await registry.session(server)).login(systemId);
    } catch (e) {
      _loginError = e.toString();
    } finally {
      _loggingIn = false;
      notifyListeners();
      await _refreshAuthState(); // recompute "any server connected"
    }
  }

  /// Clear stored tokens for [server]. The collapsed icon dims only when no
  /// server remains connected.
  Future<void> logout(
      {String server = SoliplexServerRegistry.defaultName}) async {
    await (await registry.session(server)).clearStoredTokens();
    _loginError = null;
    notifyListeners();
    await _refreshAuthState();
  }

  /// List the configured servers (names usable as the `server` arg). Reachable
  /// from the pi `soliplex_list_servers` tool.
  Future<String> _listServers(Map<String, dynamic> request) async {
    try {
      await registry.ensureDefault();
      final lines = registry.servers
          .map((s) => '- ${s.name}: '
              '${s.baseUrl.isEmpty ? '(not configured)' : s.baseUrl}')
          .join('\n');
      return 'Configured soliplex servers:\n$lines';
    } catch (e) {
      return 'Error listing soliplex servers: $e';
    }
  }

  /// Register an additional server (pi `soliplex_add_server` tool). Auth is
  /// per-server and interactive, so the user still connects via the overlay;
  /// no-auth servers work immediately.
  Future<String> _addServer(Map<String, dynamic> request) async {
    final name = (request['name'] as String?)?.trim() ?? '';
    final url = (request['url'] as String?)?.trim() ?? '';
    if (name.isEmpty) return 'Error: name is required';
    if (url.isEmpty) return 'Error: url is required';
    if (name == SoliplexServerRegistry.defaultName) {
      return 'Error: "${SoliplexServerRegistry.defaultName}" is reserved; '
          'choose another name';
    }
    try {
      await registry.addServer(name, url);
      notifyListeners(); // overlay may show the new server in its selector
      return 'Added soliplex server "$name" ($url). If it requires auth, '
          'connect via the "Connect to Soliplex" overlay; then pass '
          'server: "$name" to soliplex_query / soliplex_list_rooms / soliplex_reply.';
    } catch (e) {
      return 'Error adding soliplex server "$name": $e';
    }
  }

  Future<String> _listRooms(Map<String, dynamic> request) async {
    final server = _serverArg(request);
    try {
      final session = await registry.session(server);
      final rooms = await SoliplexClient(session).listRooms();
      await _refreshAuthState();
      // Surface other configured servers so the agent learns the names it can
      // pass as the `server` arg to query/reply elsewhere.
      final others = registry.names.where((n) => n != server).toList();
      final header = 'Rooms on "$server"'
          '${others.isEmpty ? '' : ' (other servers: ${others.join(', ')})'}:';
      if (rooms.isEmpty) return '$header\nNo rooms available.';
      return '$header\n${rooms.map((r) => '- ${r['room_id'] ?? r['id']}: '
          '${r['name'] ?? 'unnamed'} — ${r['description'] ?? 'no description'}').join('\n')}';
    } catch (e) {
      await _refreshAuthState();
      return 'Error listing rooms on "$server": $e';
    }
  }

  Future<String> _query(Map<String, dynamic> request) =>
      _runQuery(request, null);

  Future<String> _queryStream(
          Map<String, dynamic> request, ToolChunkSink emit) =>
      _runQuery(request, emit);

  Future<String> _runQuery(
      Map<String, dynamic> request, ToolChunkSink? onChunk) async {
    final server = _serverArg(request);
    final roomId = request['room_id'] as String? ?? 'search';
    final question = request['question'] as String? ?? '';
    if (question.isEmpty) return 'Error: question is required';
    try {
      final session = await registry.session(server);
      final result = await SoliplexClient(session)
          .queryRoom(roomId, question, onChunk: onChunk);
      await _refreshAuthState();
      // Seed this thread's history so a later soliplex_reply has context.
      final key =
          (serverId: server, roomId: roomId, threadId: result.threadId);
      _threadHistory[key] = [
        sox.UserMessage(id: _mid('u'), content: question),
        sox.AssistantMessage(id: _mid('a'), content: result.text),
      ];
      // Surface server + thread id so the agent can continue this conversation
      // on the SAME server/thread via soliplex_reply (multi-turn).
      return '${result.text}\n\n[soliplex server: $server, '
          'thread_id: ${result.threadId} — continue with '
          'soliplex_reply(server, room_id, thread_id, message)]';
    } catch (e) {
      await _refreshAuthState();
      return 'Error querying Soliplex: $e';
    }
  }

  Future<String> _reply(Map<String, dynamic> request) =>
      _runReply(request, null);

  Future<String> _replyStream(
          Map<String, dynamic> request, ToolChunkSink emit) =>
      _runReply(request, emit);

  /// Continue an existing soliplex thread (multi-turn). Requires `thread_id`
  /// (from a prior soliplex_query) and a `message`; the soliplex backend keeps
  /// the thread history so the model sees the earlier turns.
  Future<String> _runReply(
      Map<String, dynamic> request, ToolChunkSink? onChunk) async {
    final server = _serverArg(request);
    final roomId = request['room_id'] as String? ?? 'search';
    final threadId = request['thread_id'] as String? ?? '';
    final message = request['message'] as String? ?? '';
    if (threadId.isEmpty) return 'Error: thread_id is required';
    if (message.isEmpty) return 'Error: message is required';
    try {
      final session = await registry.session(server);
      final key = (serverId: server, roomId: roomId, threadId: threadId);
      final prior = _threadHistory[key] ?? <sox.Message>[];
      final result = await SoliplexClient(session)
          .replyToThread(roomId, threadId, prior, message, onChunk: onChunk);
      await _refreshAuthState();
      _threadHistory[key] = [
        ...prior,
        sox.UserMessage(id: _mid('u'), content: message),
        sox.AssistantMessage(id: _mid('a'), content: result),
      ];
      return '$result\n\n[soliplex server: $server, thread_id: $threadId]';
    } catch (e) {
      await _refreshAuthState();
      return 'Error replying to Soliplex thread: $e';
    }
  }
}

/// Compact multi-server overlay: a single color-coded icon (tinted when any
/// server is connected) that expands to a per-server status list with
/// connect/logout actions and an "add server" form. Per the architecture there
/// is no global "active server" — the agent names the server per tool call.
class _SoliplexAuthOverlay extends StatefulWidget {
  final SoliplexPlugin plugin;
  const _SoliplexAuthOverlay({super.key, required this.plugin});

  @override
  State<_SoliplexAuthOverlay> createState() => _SoliplexAuthOverlayState();
}

class _SoliplexAuthOverlayState extends State<_SoliplexAuthOverlay> {
  bool _expanded = false;

  List<SoliplexServer> _servers = const [];
  final Map<String, bool> _connected = {};

  // Per-server connect flow (auth-system picker for one server at a time).
  String? _connectingServer;
  Map<String, dynamic>? _authSystems;
  String? _selectedSystem;
  bool _loadingSystems = false;
  bool _authError = false; // true only on a real fetch failure (non-200/network)

  // Add-server form.
  bool _showAdd = false;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();
  String? _addError;

  @override
  void initState() {
    super.initState();
    widget.plugin.addListener(_onUpdate);
    _refreshServers();
  }

  @override
  void dispose() {
    widget.plugin.removeListener(_onUpdate);
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshServers() async {
    final servers = await widget.plugin.listServers();
    final status = <String, bool>{};
    for (final s in servers) {
      status[s.name] = await widget.plugin.isServerConnected(s.name);
    }
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _connected
        ..clear()
        ..addAll(status);
    });
  }

  Future<void> _toggleExpand() async {
    _expanded = !_expanded;
    if (mounted) setState(() {});
    if (_expanded) await _refreshServers();
  }

  Future<void> _startConnect(String server) async {
    _connectingServer = server;
    _authSystems = null;
    _selectedSystem = null;
    _authError = false;
    _loadingSystems = true;
    if (mounted) setState(() {});
    try {
      // Empty map = open / no-auth server (valid). Only a thrown error (non-200
      // or network) is a real failure.
      final systems = await widget.plugin.getAuthSystems(server: server);
      _authSystems = systems;
      if (systems.isNotEmpty) _selectedSystem = systems.keys.first;
    } catch (_) {
      _authError = true;
    } finally {
      _loadingSystems = false;
      if (mounted) setState(() {});
    }
  }

  void _cancelConnect() {
    _connectingServer = null;
    _authSystems = null;
    _selectedSystem = null;
    _authError = false;
    if (mounted) setState(() {});
  }

  Future<void> _doConnect() async {
    final server = _connectingServer;
    final system = _selectedSystem;
    if (server == null || system == null) return;
    await widget.plugin.login(system, server: server);
    _cancelConnect();
    await _refreshServers();
  }

  Future<void> _doLogout(String server) async {
    await widget.plugin.logout(server: server);
    await _refreshServers();
  }

  Future<void> _submitAdd() async {
    final err =
        await widget.plugin.addServerFromUi(_nameCtrl.text, _urlCtrl.text);
    if (!mounted) return;
    if (err != null) {
      setState(() => _addError = err);
      return;
    }
    _nameCtrl.clear();
    _urlCtrl.clear();
    setState(() {
      _addError = null;
      _showAdd = false;
    });
    await _refreshServers();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_expanded) {
      // Collapsed: a single icon, tinted when any server is connected.
      final connected = widget.plugin.authenticated;
      return Positioned(
        top: 8,
        right: 8,
        child: Material(
          key: const ValueKey('soliplex_overlay_icon'),
          elevation: 4,
          shape: const CircleBorder(),
          color: connected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _toggleExpand,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.hub,
                size: 18,
                color: connected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: 8,
      right: 8,
      child: SizedBox(
        width: 280,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.hub, size: 16, color: scheme.onSurface),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Soliplex servers',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: scheme.onSurface)),
                    ),
                    InkWell(
                      key: const ValueKey('soliplex_overlay_close'),
                      onTap: _toggleExpand,
                      child: Icon(Icons.close, size: 16, color: scheme.onSurface),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._servers.map(_serverRow),
                const Divider(height: 16),
                if (_showAdd) _addForm(scheme) else _addToggle(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverRow(SoliplexServer s) {
    final scheme = Theme.of(context).colorScheme;
    final connected = _connected[s.name] ?? false;
    final isConnecting = _connectingServer == s.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle,
                size: 10,
                color: connected ? Colors.green : scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(s.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurface)),
            ),
            if (connected)
              TextButton(
                key: ValueKey('soliplex_logout_${s.name}'),
                onPressed: () => _doLogout(s.name),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28)),
                child: const Text('Logout', style: TextStyle(fontSize: 12)),
              )
            else
              TextButton(
                key: ValueKey('soliplex_connect_${s.name}'),
                onPressed: widget.plugin.loggingIn ? null : () => _startConnect(s.name),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28)),
                child: const Text('Connect', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        if (isConnecting) _connectPicker(scheme),
      ],
    );
  }

  Widget _connectPicker(ColorScheme scheme) {
    if (_loadingSystems) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_authError) {
      return Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 6),
        child: Text('Failed to load providers',
            style: TextStyle(fontSize: 11, color: scheme.error)),
      );
    }
    if (_authSystems == null || _authSystems!.isEmpty) {
      // Open / no-auth server: nothing to log into; queries work directly.
      return Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No login required — this server is open.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            TextButton(
              key: const ValueKey('soliplex_connect_done'),
              onPressed: _cancelConnect,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28)),
              child: const Text('OK', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._authSystems!.entries.map((e) {
            final title = (e.value as Map<String, dynamic>)['title'] as String? ?? e.key;
            return InkWell(
              onTap: () => setState(() => _selectedSystem = e.key),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Radio<String>(
                    value: e.key,
                    groupValue: _selectedSystem,
                    onChanged: (v) => setState(() => _selectedSystem = v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  Text(title, style: const TextStyle(fontSize: 12)),
                ],
              ),
            );
          }),
          if (widget.plugin.loginError != null)
            Text(widget.plugin.loginError!,
                style: TextStyle(fontSize: 10, color: scheme.error)),
          Row(
            children: [
              TextButton(
                key: const ValueKey('soliplex_connect_submit'),
                onPressed:
                    (widget.plugin.loggingIn || _selectedSystem == null) ? null : _doConnect,
                child: widget.plugin.loggingIn
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Connect', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _cancelConnect,
                child: const Text('Cancel', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _addToggle(ColorScheme scheme) {
    return TextButton.icon(
      key: const ValueKey('soliplex_add_toggle'),
      onPressed: () => setState(() => _showAdd = true),
      icon: const Icon(Icons.add, size: 16),
      label: const Text('Add server', style: TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 28)),
    );
  }

  Widget _addForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('soliplex_add_name'),
          controller: _nameCtrl,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
              isDense: true, labelText: 'Name', labelStyle: TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 4),
        TextField(
          key: const ValueKey('soliplex_add_url'),
          controller: _urlCtrl,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
              isDense: true,
              labelText: 'URL (https://…)',
              labelStyle: TextStyle(fontSize: 12)),
        ),
        if (_addError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_addError!,
                style: TextStyle(fontSize: 10, color: scheme.error)),
          ),
        Row(
          children: [
            TextButton(
              key: const ValueKey('soliplex_add_submit'),
              onPressed: _submitAdd,
              child: const Text('Add', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () => setState(() {
                _showAdd = false;
                _addError = null;
              }),
              child: const Text('Cancel', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }
}
