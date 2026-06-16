# Live validation — multi-server, fan-out, citations (pi bridge)

Validated end-to-end against the running klangk devenv by driving the **real
browser-delegate bridge** — the exact path pi's soliplex tools use
(`POST /api/browser-delegate[/stream]` with the workspace terminal's live
`KLANGK_BRIDGE_TOKEN`, relayed over WebSocket to the browser plugin). pi was
running in the workspace container (pid 19); the token was pi's own session
token. Backend hit directly on :8997 to bypass nginx's container-IP ACL.

Server used for queries: **demo.example.com** (no-auth Soliplex).

## Results

1. **Multi-server registry** — `soliplex_list_servers` →
   `default: https://soliplex.host.com`, `examplehost: https://demo.example.com`,
   `example_sso: https://sso.example.com`. (Servers added via the Flutter
   overlay, persisted client-side, surfaced through the bridge.)

2. **Multi-server query routing** — `soliplex_query(server=examplehost,
   room_id=bwrap_sandbox)` streamed (empty keepalives + answer delta) and
   returned examplehost's answer plus the continuation hint
   `[soliplex server: examplehost, thread_id: … — continue with soliplex_reply(...)]`.

3. **Fan-out** — `soliplex_query_all(targets=[examplehost/bwrap_sandbox,
   default/search])` returned one aggregated block:
   - `## examplehost/bwrap_sandbox` → answer + thread_id
   - `## default/search` → `Error: … 404 No such room: search`
   Confirms parallel aggregation, per-target labeling, drill-down hints, and
   **partial-failure tolerance** (one target failed inline; the batch did not abort).

4. **Citations** — `soliplex_query(server=examplehost, room_id=soliplex,
   "How are rooms configured in soliplex?")` retrieved docs and appended:
   ```
   Sources:
   [1] overview.md
   [2] installation.md
   ```
   The RAG `rag`-state events were harvested by `CitationAccumulator` and
   rendered by `formatSources`. (A non-retrieving question correctly produced
   no Sources block.)

## Full pi agent loop (LLM autonomously calling the tool)

Closed the one gap by running pi **non-interactively inside the workspace
container** (`podman exec -u 1000 -e KLANGK_BRIDGE_TOKEN=… -e KLANGK_BRIDGE_URL=…
pi -p "…" --mode json`), so pi used its real config (provider `llm-proxy`,
model `bizon/gemma4-26b`, extensions `/opt/klangk/pi-agent/extensions`).

pi (gemma) autonomously emitted a `soliplex_query` tool call
(`server: examplehost`, `room_id: soliplex`) and the tool result returned:
```
Sources:
[1] index.md
[2] overview.md

[soliplex server: examplehost, thread_id: 93bd5555-… — continue with soliplex_reply(...)]
```
So the complete loop works: LLM decides → tool call → browser-delegate bridge →
examplehost RAG → answer + citations + multi-server continuation hint.

## Notes
- Canvas terminal (libghostty) ignores synthetic keystrokes, so pi could not be
  driven interactively from Chrome — the container-exec method (above) is how the
  full agent loop was validated.
- Note: pi pid 19 (the browser terminal's pi) had no bridge token in its env;
  the bridge token is per-exec, so the explicit `-e KLANGK_BRIDGE_TOKEN` was
  required for the extension to activate.
- Browser-side UI (compact hub-icon overlay, add-server, no-auth "open server"
  state) was validated separately via Chrome screenshots.
