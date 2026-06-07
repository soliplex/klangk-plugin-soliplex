# Changelog

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
