// Soliplex auth debug script — logs into klangk, creates a workspace,
// navigates to it, and captures the Soliplex widget.
//
// Run via:
//   cd ~/projects/klangk && devenv shell -- \
//     KLANGK_URL=https://host/klangk KLANGK_EMAIL=... KLANGK_PASSWORD=... \
//     node ~/projects/klangk-plugin-soliplex/e2e-debug/soliplex-login.mjs
//
// Environment variables:
//   KLANGK_URL       - Klangk server URL (required, e.g. https://host/klangk)
//   KLANGK_EMAIL     - Login email (required)
//   KLANGK_PASSWORD  - Login password (required)
//   KLANGK_WORKSPACE - Workspace name prefix (default: "smoke-pw")
//   BROWSER          - "firefox" to use Firefox+Xvfb, default is Chromium

import { chromium, firefox } from "playwright";
import { execSync, spawn } from "child_process";

const BASE_URL = process.env.KLANGK_URL?.replace(/\/$/, "");
const EMAIL = process.env.KLANGK_EMAIL;
const PASSWORD = process.env.KLANGK_PASSWORD;
const WS_NAME = process.env.KLANGK_WORKSPACE || `smoke-pw-${Date.now()}`;
const USE_FIREFOX = process.env.BROWSER === "firefox";
const SCREENSHOTS = new URL(".", import.meta.url).pathname;
const WIDTH = 1280;
const HEIGHT = 800;
const DISPLAY = ":99";

if (!BASE_URL || !EMAIL || !PASSWORD) {
  console.error(
    "Usage: KLANGK_URL=https://host/klangk KLANGK_EMAIL=... KLANGK_PASSWORD=... node soliplex-login.mjs",
  );
  process.exit(1);
}

// --- Xvfb (only needed for Firefox) ---

function startXvfb() {
  try {
    execSync(`xdpyinfo -display ${DISPLAY} 2>/dev/null`, { stdio: "ignore" });
    return null;
  } catch {
    /* not running */
  }
  const xvfb = spawn(
    "Xvfb",
    [DISPLAY, "-screen", "0", `${WIDTH}x${HEIGHT}x24`],
    { stdio: "ignore", detached: true },
  );
  xvfb.unref();
  execSync("sleep 0.5");
  return xvfb;
}

// --- Flutter helpers ---

async function waitForFlutter(page) {
  await page.waitForFunction(
    () => !document.body.textContent?.includes("Loading, please wait"),
    { timeout: 90_000 },
  );
  await page.waitForSelector("flutter-view", { timeout: 30_000 });
  await page.waitForTimeout(500);
}

function fv(page) {
  return page.locator("flutter-view");
}

async function dismissAccessibility(page) {
  const btn = page.locator("button", { hasText: "Enable accessibility" });
  if (await btn.isVisible({ timeout: 500 }).catch(() => false)) {
    await btn.click();
    await page.waitForTimeout(300);
  }
}

async function screenshot(page, name) {
  const path = `${SCREENSHOTS}/${name}`;
  await page.screenshot({ path });
  console.log(`   Screenshot: ${name}`);
}

// --- API helpers ---

const API_BASE = BASE_URL;

async function apiLogin(request) {
  const resp = await request.post(`${API_BASE}/api/v1/auth/login`, {
    data: { email: EMAIL, password: PASSWORD },
  });
  if (!resp.ok()) {
    throw new Error(`Login failed: ${resp.status()} ${await resp.text()}`);
  }
  const data = await resp.json();
  return {
    token: data.access_token,
    headers: { Authorization: `Bearer ${data.access_token}` },
  };
}

async function apiCreateWorkspace(request, headers, name) {
  const resp = await request.post(`${API_BASE}/api/v1/workspaces`, {
    headers,
    data: { name },
  });
  if (!resp.ok()) {
    const body = await resp.text();
    // 409 = already exists, try to find its ID
    if (resp.status() === 409) {
      const listResp = await request.get(`${API_BASE}/api/v1/workspaces`, {
        headers,
      });
      const workspaces = await listResp.json();
      const ws = workspaces.find((w) => w.name === name);
      if (ws) return ws.id;
    }
    throw new Error(`Workspace creation failed: ${resp.status()} ${body}`);
  }
  const ws = await resp.json();
  return ws.id;
}

async function apiDeleteWorkspace(request, headers, id) {
  await request.delete(`${API_BASE}/api/v1/workspaces/${id}`, { headers });
}

// --- Main ---

const xvfb = USE_FIREFOX ? startXvfb() : null;

try {
  const launcher = USE_FIREFOX ? firefox : chromium;
  const launchOpts = USE_FIREFOX
    ? { headless: false, env: { ...process.env, DISPLAY } }
    : { headless: true };
  console.log(`Browser: ${USE_FIREFOX ? "Firefox" : "Chromium"}`);
  const browser = await launcher.launch(launchOpts);
  const context = await browser.newContext({
    viewport: { width: WIDTH, height: HEIGHT },
    ignoreHTTPSErrors: true,
    baseURL: BASE_URL,
  });
  const page = await context.newPage();

  page.on("console", (msg) => {
    const t = msg.type();
    if (t === "error" || t === "warning" || t === "log") {
      console.log(`[browser ${t}] ${msg.text()}`);
    }
  });

  // 1. API login + create workspace
  console.log("1. API login as", EMAIL);
  const { token, headers } = await apiLogin(context.request);
  console.log("   Token obtained");

  console.log("2. Creating workspace:", WS_NAME);
  const workspaceId = await apiCreateWorkspace(
    context.request,
    headers,
    WS_NAME,
  );
  console.log("   Workspace ID:", workspaceId);

  // 2. UI login (Flutter needs to be logged in too)
  console.log("3. UI login...");
  await page.goto(BASE_URL);
  await waitForFlutter(page);
  await dismissAccessibility(page);
  await screenshot(page, "01-login-page.png");

  const cx = WIDTH / 2;
  const f = fv(page);

  // Email field
  await f.click({ position: { x: cx, y: HEIGHT * 0.53 }, force: true });
  await page.waitForTimeout(200);
  await page.keyboard.type(EMAIL);

  // Password field
  await f.click({ position: { x: cx, y: HEIGHT * 0.61 }, force: true });
  await page.waitForTimeout(200);
  await page.keyboard.type(PASSWORD);

  // Login button
  await f.click({ position: { x: cx, y: HEIGHT * 0.70 }, force: true });

  try {
    await page.waitForFunction(() => document.title.match(/workspaces/i), {
      timeout: 15_000,
    });
  } catch {
    await screenshot(page, "02-login-failed.png");
    console.log("   ERROR: Login failed, check 02-login-failed.png");
    await browser.close();
    process.exit(1);
  }
  console.log("   Logged in, page title:", await page.title());
  await screenshot(page, "02-workspace-list.png");

  // 3. Navigate to workspace
  console.log("4. Opening workspace...");

  // Listen for container_ready on WebSocket
  let containerReady;
  const containerPromise = new Promise((resolve, reject) => {
    containerReady = resolve;
    setTimeout(() => reject(new Error("Container not ready in 120s")), 120_000);
  });
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      const text = frame.payload.toString();
      if (text.includes("container_ready")) containerReady();
    });
  });

  await page.goto(`${BASE_URL}/#/workspace/${workspaceId}`, {
    waitUntil: "load",
  });
  await waitForFlutter(page);

  console.log("   Waiting for container...");
  await containerPromise;
  console.log("   Container ready");
  await dismissAccessibility(page);
  await page.waitForTimeout(3000);
  await screenshot(page, "03-workspace.png");
  console.log("   Page title:", await page.title());

  // 4. Click the Soliplex widget (top-right circular icon)
  console.log("5. Clicking Soliplex widget...");
  const box = await fv(page).boundingBox();
  const fvX = box?.x ?? 0;
  const fvY = box?.y ?? 0;
  await page.mouse.click(fvX + WIDTH - 32, fvY + 80);
  await page.waitForTimeout(2000);
  await screenshot(page, "05-soliplex-overlay.png");

  // 5. Click "Connect" on the default server row to expand auth options
  console.log("6. Clicking Connect on default server...");
  await page.mouse.click(fvX + 1224, fvY + 111);
  await page.waitForTimeout(2000);
  await screenshot(page, "06-auth-system-select.png");

  // 6. Select "Authenticate with Enfold" radio button, then click Connect
  console.log("7. Selecting Enfold auth and clicking Connect...");

  // "Authenticate with Enfold" radio is at roughly x=1038, y=169
  await page.mouse.click(fvX + 1038, fvY + 169);
  await page.waitForTimeout(500);
  await screenshot(page, "06b-enfold-selected.png");

  const popupPromise = context
    .waitForEvent("page", { timeout: 15_000 })
    .catch(() => null);

  // Inner "Connect" button is at roughly x=1055, y=201
  await page.mouse.click(fvX + 1055, fvY + 201);
  await page.waitForTimeout(1000);
  await screenshot(page, "07-after-inner-connect.png");

  const popup = await popupPromise;
  if (popup) {
    console.log("   Popup opened:", popup.url());
    await popup.waitForLoadState("networkidle").catch(() => {});
    await popup.screenshot({
      path: `${SCREENSHOTS}/08-popup.png`,
    });
    console.log("   Screenshot: 08-popup.png");

    // Try to log in on the popup (Soliplex credentials)
    const SOLIPLEX_USER = process.env.SOLIPLEX_USER || "";
    const SOLIPLEX_PASSWORD = process.env.SOLIPLEX_PASSWORD || "";
    // Log all navigation and console events on the popup
    popup.on("framenavigated", (frame) => {
      if (frame === popup.mainFrame()) {
        console.log("   [popup nav]", frame.url());
      }
    });
    popup.on("console", (msg) => {
      console.log(`   [popup ${msg.type()}] ${msg.text()}`);
    });

    if (SOLIPLEX_USER && SOLIPLEX_PASSWORD) {
      console.log("   Attempting Soliplex login in popup...");
      // Keycloak login form — find username and password fields
      const userInput = popup.locator(
        'input[name="username"], input[id="username"]',
      ).first();
      const passInput = popup.locator(
        'input[name="password"], input[id="password"]',
      ).first();

      if ((await userInput.count()) && (await passInput.count())) {
        // Use keyboard.type() instead of fill() — some Keycloak themes
        // have JS that clears programmatically-set values
        await userInput.click();
        await popup.keyboard.type(SOLIPLEX_USER);
        await passInput.click();
        await popup.keyboard.type(SOLIPLEX_PASSWORD);
        await popup.screenshot({
          path: `${SCREENSHOTS}/09-popup-filled.png`,
        });
        console.log("   Screenshot: 09-popup-filled.png");

        // Submit — press Enter from the password field
        console.log("   Pressing Enter to submit");
        await passInput.press("Enter");

        // Wait for redirect chain: Keycloak → Soliplex backend → klangk callback
        console.log("   Waiting for redirect chain...");
        try {
          await popup.waitForURL("**/soliplex-auth-callback*", {
            timeout: 15_000,
          });
          console.log("   Popup redirected to callback:", popup.url());
        } catch {
          console.log("   Popup URL after wait:", popup.url());
          // Dump any error messages from Keycloak
          const errorEl = popup.locator(
            '.alert-error, .kc-feedback-text, #input-error, [class*="error"]',
          );
          const errorCount = await errorEl.count();
          if (errorCount) {
            for (let i = 0; i < errorCount; i++) {
              const text = await errorEl.nth(i).textContent().catch(() => "");
              if (text.trim()) console.log("   Keycloak error:", text.trim());
            }
          }
          // Also dump full page text
          const pageText = await popup.locator("body").innerText().catch(() => "");
          console.log("   Popup page text:", pageText.slice(0, 300));
        }
        await popup.waitForTimeout(2000);
        await popup.screenshot({
          path: `${SCREENSHOTS}/10-popup-after-login.png`,
        }).catch(() => {}); // popup may have closed
        console.log("   Screenshot: 10-popup-after-login.png (if popup still open)");
      } else {
        console.log("   No username/password fields found in popup");
        const popupContent = await popup.content();
        console.log("   Popup HTML snippet:", popupContent.slice(0, 500));
      }
    } else {
      console.log("   No SOLIPLEX_USER/SOLIPLEX_PASSWORD set, skipping popup login");
    }

    // Wait for popup to close and token to be captured
    console.log("   Waiting for auth to complete...");
    for (let i = 0; i < 20; i++) {
      await page.waitForTimeout(1000);
      // Check if popup closed
      if (popup.isClosed()) {
        console.log("   Popup closed after", i + 1, "seconds");
        break;
      }
    }
    if (!popup.isClosed()) {
      console.log("   Popup still open after 20s, URL:", popup.url());
    }
  } else {
    console.log("   No popup detected");
  }

  // Wait for overlay to update
  await page.waitForTimeout(3000);

  // Final state
  await screenshot(page, "11-final-state.png");
  console.log("   Final page title:", await page.title());

  // Clean up workspace
  console.log("\n8. Cleaning up workspace...");
  await apiDeleteWorkspace(context.request, headers, workspaceId);
  console.log("   Workspace deleted");

  console.log("\nDone. Check screenshots in e2e-debug/");
  await browser.close();
} finally {
  if (xvfb) xvfb.kill();
}
