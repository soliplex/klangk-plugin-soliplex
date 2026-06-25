# Soliplex E2E Debug Scripts

Playwright scripts for debugging the Soliplex plugin's OAuth auth flow.
Run from the klangk devenv shell, which provides Playwright and matching
browser binaries.

## Prerequisites

- [klangk](https://github.com/mcdonc/klangk) repo checked out with
  `devenv shell` working
- A running klangk instance with the soliplex plugin installed

## Scripts

### soliplex-login.mjs

End-to-end test of the full Soliplex auth flow: logs into klangk,
creates a workspace, opens the Soliplex widget, selects an auth
provider, logs in via the IdP popup, and verifies the token is
captured.

```bash
cd ~/projects/klangk && devenv shell -- \
  KLANGK_URL=https://host/klangk \
  KLANGK_EMAIL=user@example.com \
  KLANGK_PASSWORD=... \
  SOLIPLEX_USER=... \
  SOLIPLEX_PASSWORD=... \
  node ~/projects/klangk-plugin-soliplex/e2e-debug/soliplex-login.mjs
```

| Variable | Required | Description |
|---|---|---|
| `KLANGK_URL` | yes | Klangk server URL (e.g. `https://host/klangk`) |
| `KLANGK_EMAIL` | yes | Klangk login email |
| `KLANGK_PASSWORD` | yes | Klangk login password |
| `KLANGK_WORKSPACE` | no | Workspace name prefix (default: `smoke-pw-<timestamp>`) |
| `SOLIPLEX_USER` | no | Soliplex IdP username (skips popup login if unset) |
| `SOLIPLEX_PASSWORD` | no | Soliplex IdP password |
| `BROWSER` | no | `firefox` to use Firefox+Xvfb (default: Chromium) |

Screenshots are saved to this directory as `01-*.png` through `11-*.png`.

### soliplex-direct-login.mjs

Traces the Soliplex OAuth redirect chain directly (no klangk), useful
for debugging where `?token=` ends up in the redirect URL.

```bash
cd ~/projects/klangk && devenv shell -- \
  SOLIPLEX_URL=https://rag.example.com \
  SOLIPLEX_USER=... \
  SOLIPLEX_PASSWORD=... \
  node ~/projects/klangk-plugin-soliplex/e2e-debug/soliplex-direct-login.mjs
```

| Variable | Required | Description |
|---|---|---|
| `SOLIPLEX_URL` | yes | Soliplex server URL |
| `SOLIPLEX_USER` | yes | IdP username |
| `SOLIPLEX_PASSWORD` | yes | IdP password |

## Notes

- Chromium is used by default because Flutter needs WebGL, which
  headless Firefox lacks (no SwiftShader). Use `BROWSER=firefox` with
  Xvfb and Mesa drivers if you need Firefox-specific testing.
- Screenshots are gitignored — they may contain session tokens in URLs.
- Credentials are always passed via environment variables, never
  hardcoded.
