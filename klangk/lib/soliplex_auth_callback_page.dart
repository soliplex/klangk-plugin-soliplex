import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Callback landing page for the Soliplex OAuth popup flow.
///
/// When the IdP redirects back to this route with `?token=...` in the URL,
/// this page sends the token data back to the opener window via postMessage
/// and closes itself. This avoids the polling approach (which breaks in
/// Firefox because cross-origin navigation severs the popup opener handle).
class SoliplexAuthCallbackPage extends StatefulWidget {
  final Map<String, String> queryParameters;

  const SoliplexAuthCallbackPage({
    super.key,
    required this.queryParameters,
  });

  @override
  State<SoliplexAuthCallbackPage> createState() =>
      _SoliplexAuthCallbackPageState();
}

class _SoliplexAuthCallbackPageState extends State<SoliplexAuthCallbackPage> {
  String _status = 'Processing authentication...';

  @override
  void initState() {
    super.initState();
    _handleCallback();
  }

  void _handleCallback() {
    // The Soliplex backend appends ?token=... to the return_to URL. With hash
    // routing the token lands in the PAGE query string (before the #), not in
    // the hash fragment's query. GoRouter only sees the hash query, so we read
    // from window.location.search directly.
    final pageQuery = Uri.splitQueryString(
      web.window.location.search.replaceFirst('?', ''),
    );
    // Fall back to GoRouter-provided params in case the server ever puts
    // them in the hash fragment instead.
    String? param(String key) =>
        pageQuery[key] ?? widget.queryParameters[key];

    final token = param('token');
    if (token == null || token.isEmpty) {
      setState(() => _status = 'No token received.');
      return;
    }

    // Send token data back to the opener (the klangk workspace page)
    // via postMessage. The opener's listener picks this up and stores
    // the tokens, then closes this popup.
    try {
      final openerRaw = web.window.opener;
      if (openerRaw != null) {
        final opener = openerRaw as web.Window;
        final message = {
          'type': 'soliplex-auth-callback',
          'token': token,
          'refresh_token': param('refresh_token') ?? '',
          'expires_in': param('expires_in') ?? '',
        }.entries.map((e) => '${e.key}=${e.value}').join('&');
        opener.postMessage(
          message.toJS,
          web.window.location.origin.toJS,
        );
        setState(() => _status = 'Authenticated. This window will close.');
        // Close after a short delay so the message is received
        Future.delayed(const Duration(milliseconds: 500), () {
          web.window.close();
        });
      } else {
        setState(() => _status = 'No opener window found.');
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(_status, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}
