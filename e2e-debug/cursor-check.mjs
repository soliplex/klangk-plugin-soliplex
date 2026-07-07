// Cursor-check script — logs into klangk, opens a workspace, expands the
// Soliplex overlay, hovers over text elements (server names, "Add server"),
// and captures the computed CSS cursor on the flutter-view element.
//
// Run via:
//   cd ~/projects/klangk && devenv shell -- \
//     KLANGK_URL=https://host/klangk KLANGK_EMAIL=... KLANGK_PASSWORD=... \
//     node ~/projects/klangk-plugin-soliplex/e2e-debug/cursor-check.mjs
//
// Environment variables:
//   KLANGK_URL       - Klangk server URL (required, e.g. https://host/klangk)
//   KLANGK_EMAIL     - Login email (required)
//   KLANGK_PASSWORD  - Login password (required)
//   KLANGK_WORKSPACE - Workspace name prefix (default: "cursor-pw")
//   BROWSER          - "firefox" to use Firefox+Xvfb, default is Chromium

import { chromium, firefox } from "playwright";
import { execSync, spawn } from "child_process";

const BASE_URL = process.env.KLANGK_URL?.replace(/\/$/, "");
const EMAIL = process.env.KLANGK_EMAIL;
const PASSWORD = process.env.KLANGK_PASSWORD;
const WS_NAME = process.env.KLANGK_WORKSPACE || `cursor-pw-${Date.now()}`;
const USE_FIREFOX = process.env.BROWSER === "firefox";
const SCREENSHOTS = new URL(".", import.meta.url).pathname;
const WIDTH = 1280;
const HEIGHT = 800;
const DISPLAY = ":99";

if (!BASE_URL || !EMAIL || !PASSWORD) {
  console.error(
    "Usage: KLANGK_URL=... KLANGK_EMAIL=... KLANGK_PASSWORD=... node cursor-check.mjs",
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

// --- Cursor checking ---

// Get the computed cursor CSS value from the flutter-view's shadow DOM.
// Flutter Web sets cursor on the glass-pane or host element inside the
// shadow root. We check both the flutter-view element itself and any
// elements inside its shadow DOM.
async function getCursor(page) {
  return page.evaluate(() => {
    // Check flutter-view element
    const fv = document.querySelector("flutter-view");
    if (!fv) return { error: "no flutter-view" };

    const fvCursor = getComputedStyle(fv).cursor;

    // Check shadow DOM elements
    const shadow = fv.shadowRoot;
    let glassPaneCursor = null;
    let hostCursor = null;
    if (shadow) {
      const glassPane = shadow.querySelector("flt-glass-pane");
      if (glassPane) glassPaneCursor = getComputedStyle(glassPane).cursor;
      // Also check the host element and any platform views
      for (const el of shadow.querySelectorAll("*")) {
        const c = getComputedStyle(el).cursor;
        if (c === "text") {
          hostCursor = `text (on ${el.tagName.toLowerCase()})`;
          break;
        }
      }
    }

    // Also check body
    const bodyCursor = getComputedStyle(document.body).cursor;

    return { fvCursor, glassPaneCursor, hostCursor, bodyCursor };
  });
}

// --- API helpers ---

async function apiLogin(request) {
  const resp = await request.post(`${BASE_URL}/api/v1/auth/login`, {
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
  const resp = await request.post(`${BASE_URL}/api/v1/workspaces`, {
    headers,
    data: { name },
  });
  if (!resp.ok()) {
    if (resp.status() === 409) {
      const listResp = await request.get(`${BASE_URL}/api/v1/workspaces`, {
        headers,
      });
      const workspaces = await listResp.json();
      const ws = workspaces.find((w) => w.name === name);
      if (ws) return ws.id;
    }
    throw new Error(
      `Workspace creation failed: ${resp.status()} ${await resp.text()}`,
    );
  }
  return (await resp.json()).id;
}

async function apiDeleteWorkspace(request, headers, id) {
  await request.delete(`${BASE_URL}/api/v1/workspaces/${id}`, { headers });
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
    if (t === "error") console.log(`[browser ${t}] ${msg.text()}`);
  });

  // 1. API login + create workspace
  console.log("1. API login as", EMAIL);
  const { headers } = await apiLogin(context.request);

  console.log("2. Creating workspace:", WS_NAME);
  const workspaceId = await apiCreateWorkspace(
    context.request,
    headers,
    WS_NAME,
  );
  console.log("   Workspace ID:", workspaceId);

  // 2. UI login
  console.log("3. UI login...");
  await page.goto(BASE_URL);
  await waitForFlutter(page);
  await dismissAccessibility(page);

  const cx = WIDTH / 2;
  const f = fv(page);

  await f.click({ position: { x: cx, y: HEIGHT * 0.53 }, force: true });
  await page.waitForTimeout(200);
  await page.keyboard.type(EMAIL);

  await f.click({ position: { x: cx, y: HEIGHT * 0.61 }, force: true });
  await page.waitForTimeout(200);
  await page.keyboard.type(PASSWORD);

  await f.click({ position: { x: cx, y: HEIGHT * 0.7 }, force: true });

  try {
    await page.waitForFunction(() => document.title.match(/workspaces/i), {
      timeout: 15_000,
    });
  } catch {
    await screenshot(page, "cursor-01-login-failed.png");
    console.log("   ERROR: Login failed");
    await browser.close();
    process.exit(1);
  }
  console.log("   Logged in");

  // 3. Navigate to workspace
  console.log("4. Opening workspace...");

  let containerReady;
  const containerPromise = new Promise((resolve, reject) => {
    containerReady = resolve;
    setTimeout(() => reject(new Error("Container not ready in 120s")), 120_000);
  });
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      if (frame.payload.toString().includes("container_ready"))
        containerReady();
    });
  });

  await page.goto(`${BASE_URL}/#/workspace/${workspaceId}`, {
    waitUntil: "load",
  });
  await waitForFlutter(page);
  await containerPromise;
  await dismissAccessibility(page);
  await page.waitForTimeout(3000);
  console.log("   Container ready");

  // 4. Find and click the Soliplex overlay icon (top-right)
  console.log("5. Opening Soliplex overlay...");
  const box = await fv(page).boundingBox();
  const fvX = box?.x ?? 0;
  const fvY = box?.y ?? 0;

  // Soliplex icon is in the top-right area of the settings tab
  // First click the settings gear/tab to get to the right panel
  await page.mouse.click(fvX + WIDTH - 32, fvY + 80);
  await page.waitForTimeout(2000);
  await screenshot(page, "cursor-02-overlay-open.png");

  // 5. Now hover over different elements and check the cursor
  console.log("\n=== CURSOR CHECK ===\n");

  // Check baseline cursor (over empty area)
  await page.mouse.move(fvX + 100, fvY + 100);
  await page.waitForTimeout(500);
  const baselineCursor = await getCursor(page);
  console.log("Baseline (empty area):", JSON.stringify(baselineCursor));

  // The overlay should be at roughly the top-right.
  // Server rows are approximately:
  //   "default" text: around x=WIDTH-240, y=95 (relative to flutter-view)
  //   "rag" text: around x=WIDTH-240, y=115
  //   "Add server": around x=WIDTH-210, y=145

  // Hover over the "default" server name text
  const overlayX = WIDTH - 220;
  await page.mouse.move(fvX + overlayX, fvY + 95);
  await page.waitForTimeout(500);
  const defaultCursor = await getCursor(page);
  console.log(
    '"default" server name:',
    JSON.stringify(defaultCursor),
  );
  await screenshot(page, "cursor-03-hover-default.png");

  // Hover over the second server name (if present)
  await page.mouse.move(fvX + overlayX, fvY + 115);
  await page.waitForTimeout(500);
  const ragCursor = await getCursor(page);
  console.log(
    '"rag" server name:',
    JSON.stringify(ragCursor),
  );
  await screenshot(page, "cursor-04-hover-rag.png");

  // Hover over "Add server"
  await page.mouse.move(fvX + overlayX, fvY + 150);
  await page.waitForTimeout(500);
  const addServerCursor = await getCursor(page);
  console.log('"Add server":  ', JSON.stringify(addServerCursor));
  await screenshot(page, "cursor-05-hover-add-server.png");

  // Hover over "Soliplex servers" header text
  await page.mouse.move(fvX + overlayX, fvY + 72);
  await page.waitForTimeout(500);
  const headerCursor = await getCursor(page);
  console.log('"Soliplex servers":', JSON.stringify(headerCursor));
  await screenshot(page, "cursor-06-hover-header.png");

  // Move away and back to check if cursor updates
  console.log("\n--- Move away and back ---");
  await page.mouse.move(fvX + 100, fvY + 400);
  await page.waitForTimeout(500);
  await page.mouse.move(fvX + overlayX, fvY + 95);
  await page.waitForTimeout(500);
  const defaultCursor2 = await getCursor(page);
  console.log(
    '"default" (2nd hover):',
    JSON.stringify(defaultCursor2),
  );

  // Summary
  console.log("\n=== SUMMARY ===");
  const allCursors = [
    { label: "baseline", cursor: baselineCursor },
    { label: "default", cursor: defaultCursor },
    { label: "rag", cursor: ragCursor },
    { label: "add server", cursor: addServerCursor },
    { label: "header", cursor: headerCursor },
  ];

  let hasTextCursor = false;
  for (const { label, cursor } of allCursors) {
    const fvC = cursor.fvCursor || "?";
    const gpC = cursor.glassPaneCursor || "?";
    const bodyC = cursor.bodyCursor || "?";
    const hostC = cursor.hostCursor || "none";
    const bad =
      fvC === "text" || gpC === "text" || bodyC === "text" || hostC.includes("text");
    if (bad) hasTextCursor = true;
    console.log(
      `  ${bad ? "FAIL" : "OK  "} ${label}: fv=${fvC} glass=${gpC} body=${bodyC} host=${hostC}`,
    );
  }

  if (hasTextCursor) {
    console.log("\nFAILED: text-select cursor detected on overlay elements");
  } else {
    console.log("\nPASSED: no text-select cursor on overlay elements");
  }

  // Clean up
  console.log("\n6. Cleaning up workspace...");
  await apiDeleteWorkspace(context.request, headers, workspaceId);
  console.log("   Done");

  await browser.close();
  process.exit(hasTextCursor ? 1 : 0);
} finally {
  if (xvfb) xvfb.kill();
}
