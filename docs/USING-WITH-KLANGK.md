# Soliplex ⇄ Klangk integration — what we delivered & how to use it

This is the Soliplex plugin for Klangk. It lets a workspace's **Pi agent** query a
Soliplex RAG server (`soliplex_query`), continue a thread (`soliplex_reply`), and
list rooms (`soliplex_list_rooms`). The plugin lives **here in the Soliplex org**;
Klangk consumes it as an external plugin. **No Soliplex code lives in the klangk
repo.**

---

## What we delivered

**`soliplex/klangk-plugin-soliplex`** (this repo) — the plugin:
- **Flutter plugin** (`klangk/`): runs in the Klangk web app, holds the Soliplex
  auth, talks to the Soliplex server. Tools: `soliplex_list_rooms`,
  `soliplex_query`, `soliplex_reply`.
- **Pi extension** (`extension.ts`): registers those tools for the agent and
  relays calls to the app over Klangk's browser-delegate **streaming** bridge.
- **Streaming, no 30s timeout:** uses `/api/browser-delegate/stream` and relays
  every AG-UI event as a keepalive chunk, so a long RAG/LLM answer keeps the
  socket alive (the bridge's idle timeout only fires on a true gap).
- **Multi-turn:** `soliplex_query` returns a `thread_id`; `soliplex_reply`
  continues that thread (full conversation history is sent each turn — the
  Soliplex backend does not replay it).
- **Auth:** OIDC login via the in-app "Connect to Soliplex" overlay; also works
  against no-auth Soliplex deployments. Web login uses an absolute `return_to`
  on the Klangk app origin (see the auth caveat below).
- **Tool-call display:** the agent's call line shows
  `soliplex_query(roomId: …, message: …)`.

**`soliplex/frontend` PR #333 (merged)** — pinned the `ag_ui` git dep so
`soliplex_client` resolves/compiles for external consumers (no override needed).

**Klangk** — already has the generic streaming browser-delegate bridge on `main`
(klangk#79 + #91). **Nothing to add to the klangk repo.**

---

## How to incorporate it (per developer)

Prereqs: a working Klangk dev checkout (`devenv`), Docker running, and a Soliplex
server URL (e.g. `https://soliplex.host.com`).

1. **Declare the plugin** in `$KLANGK_PLUGINS_DIR/plugins.yaml`
   (dev default: `.devenv/state/klangk/plugins/plugins.yaml`):
   ```yaml
   plugins:
     - name: soliplex
       git: https://github.com/soliplex/klangk-plugin-soliplex.git
       ref: main
   ```

2. **Point Klangk at your Soliplex server** in `.env`:
   ```
   SOLIPLEX_URL=https://soliplex.host.com
   ```

3. **Fetch, build, restart:**
   ```bash
   update-plugins      # vendors this plugin into $KLANGK_PLUGINS_DIR
   rebuild             # dockerbuild (bakes the Pi extension into the workspace
                       # image) + flutterbuildweb (builds the app with the plugin)
   restart             # or `devenv up` — so the backend reads SOLIPLEX_URL
   ```

4. **Use it:** open a workspace → click **Connect to Soliplex** and log in →
   in the **Terminal** run `pi` and ask it to use the room, e.g.
   *“use soliplex_query on room `bwrap_sandbox` to ask: …”*. Continue with
   `soliplex_reply` using the `thread_id` it returns.

---

## Caveats teammates must know

- **OIDC return_to allow-list (most likely gotcha).** The web login popup returns
  to `<your klangk origin>/soliplex-auth-callback` (e.g. `http://localhost:8995/…`).
  The **Soliplex server must allow that origin** as a return_to / callback. If
  login spins or lands on the Soliplex domain with “session expired/missing”,
  your klangk origin isn’t allow-listed on the Soliplex server — get it added.
- **Bridge idle timeout** is `KLANGK_BRIDGE_TIMEOUT_SECONDS` (default 30s) and
  bounds the gap *between* streamed chunks, not total duration. The plugin’s
  keepalives normally keep it from firing; raise it only if a Soliplex deployment
  goes silent for >30s mid-answer.
- **No-auth Soliplex** (e.g. a demo) works with no login; the “Connect” overlay
  is harmless.
- **`KLANGK_TEST_MODE=1`** is only needed for the `/api/test/*` debug endpoints —
  not for normal use.

---

## Architecture (one line)

`pi agent (container)` → `extension.ts` → `POST /api/browser-delegate/stream`
(Klangk backend) → WebSocket → `Flutter SoliplexPlugin` (holds auth) →
`Soliplex server`. Responses stream back the same path.
