# Changelog

## 0.2.1

- Fix web login against Soliplex backends with soliplex#1415: the auth
  callback now delivers `token` / `refresh_token` / `expires_in` in the URL
  **fragment** of `return_to` instead of the query string. The popup poller's
  `extractCallbackParams` reads them from the fragment (query-first, matching
  the Soliplex web client's `callback_params_parser`), so older query-string
  backends keep working. Native (`flutter_appauth`) login is unaffected.

## 0.2.0

- Extracted from the Klangk `macos-native` tree into a standalone Soliplex-org
  package, written against Klangk `main`.
- Stream `soliplex_query` deltas as they arrive (was klangk PR #80): add
  `streamingHandlers['soliplex_query']` and thread an optional `onChunk` sink
  through `SoliplexClient.queryRoom`, fed by `soliplex_client`'s
  `AgUiStreamClient` text deltas. Fixes the 30 s browser-delegate timeout for
  long RAG + LLM answers.
- Drop the temporary `klangk_plugin_api` fork override — the streaming API
  (`StreamingToolHandler` / `ToolChunkSink` / `ToolPlugin.streamingHandlers`)
  is merged upstream.
