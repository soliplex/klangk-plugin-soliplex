// Direct Soliplex login test — traces the OAuth redirect chain to see
// where ?token= ends up.
//
// Run via:
//   cd ~/projects/klangk && devenv shell -- \
//     SOLIPLEX_URL=https://rag.enfoldsystems.net \
//     SOLIPLEX_USER=chris SOLIPLEX_PASSWORD=password \
//     node ~/projects/klangk-plugin-soliplex/e2e-debug/soliplex-direct-login.mjs

import { chromium } from "playwright";

const SOLIPLEX_URL = process.env.SOLIPLEX_URL;
const USER = process.env.SOLIPLEX_USER;
const PASSWORD = process.env.SOLIPLEX_PASSWORD;
const SCREENSHOTS = new URL(".", import.meta.url).pathname;

if (!SOLIPLEX_URL || !USER || !PASSWORD) {
  console.error(
    "Usage: SOLIPLEX_URL=https://... SOLIPLEX_USER=... SOLIPLEX_PASSWORD=... node soliplex-direct-login.mjs",
  );
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 800, height: 600 },
    ignoreHTTPSErrors: true,
  });

  // 1. Discover auth systems
  console.log("1. Fetching auth systems from", SOLIPLEX_URL);
  const resp = await context.request.get(`${SOLIPLEX_URL}/api/login`);
  const systems = await resp.json();
  console.log("   Auth systems:", JSON.stringify(systems, null, 2));

  // Pick the first system (or "pydio" / "enfold" if available)
  const systemId =
    Object.keys(systems).find((k) => k.match(/enfold|pydio/i)) ||
    Object.keys(systems)[0];
  console.log("   Using system:", systemId);

  // 2. Build the login URL with a simple return_to
  const returnTo = `${SOLIPLEX_URL}/api/health`;
  const loginUrl = `${SOLIPLEX_URL}/api/login/${systemId}?return_to=${encodeURIComponent(returnTo)}`;
  console.log("\n2. Login URL:", loginUrl);

  const page = await context.newPage();

  // Track all redirects
  const redirects = [];
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) {
      redirects.push(frame.url());
      console.log("   [nav]", frame.url());
    }
  });
  page.on("console", (msg) => {
    console.log(`   [browser ${msg.type()}] ${msg.text()}`);
  });

  // 3. Navigate to login URL
  console.log("\n3. Navigating to login URL...");
  await page.goto(loginUrl, { waitUntil: "networkidle" });
  await page.screenshot({ path: `${SCREENSHOTS}/direct-01-login-page.png` });
  console.log("   Screenshot: direct-01-login-page.png");
  console.log("   Current URL:", page.url());

  // 4. Fill in credentials on the Keycloak page
  console.log("\n4. Logging in as", USER);
  const userInput = page
    .locator('input[name="username"], input[id="username"]')
    .first();
  const passInput = page
    .locator('input[name="password"], input[id="password"]')
    .first();

  if (!(await userInput.count()) || !(await passInput.count())) {
    console.log("   ERROR: No login form found");
    console.log("   Page content:", (await page.content()).slice(0, 500));
    await browser.close();
    process.exit(1);
  }

  await userInput.click();
  await page.keyboard.type(USER);
  await passInput.click();
  await page.keyboard.type(PASSWORD);
  await page.screenshot({ path: `${SCREENSHOTS}/direct-02-filled.png` });
  console.log("   Screenshot: direct-02-filled.png");

  // 5. Submit and follow redirects
  console.log("\n5. Submitting login...");
  await passInput.press("Enter");

  // Wait for the redirect chain to complete
  try {
    await page.waitForURL("**/health*", { timeout: 15_000 });
    console.log("   Landed on health endpoint");
  } catch {
    console.log("   Did not reach /health");
  }

  await page.waitForTimeout(2000);
  await page.screenshot({ path: `${SCREENSHOTS}/direct-03-result.png` });
  console.log("   Screenshot: direct-03-result.png");
  console.log("   Final URL:", page.url());

  // Check if token is in the URL
  const finalUrl = page.url();
  if (finalUrl.includes("token=")) {
    console.log("   TOKEN FOUND in URL");
    const parsed = new URL(finalUrl);
    console.log("   token:", parsed.searchParams.get("token")?.slice(0, 20) + "...");
    console.log("   refresh_token:", parsed.searchParams.get("refresh_token")?.slice(0, 20) + "...");
    console.log("   expires_in:", parsed.searchParams.get("expires_in"));
  } else {
    console.log("   NO TOKEN in URL");
  }

  // Show the page body (health endpoint returns JSON)
  const body = await page.locator("body").innerText().catch(() => "");
  console.log("   Body:", body.slice(0, 200));

  // 6. Now try with a hash-based return_to (like klangk uses)
  console.log("\n6. Testing with hash-based return_to...");
  const hashReturnTo = `${SOLIPLEX_URL}/#/callback-test`;
  const hashLoginUrl = `${SOLIPLEX_URL}/api/login/${systemId}?return_to=${encodeURIComponent(hashReturnTo)}`;
  console.log("   Login URL:", hashLoginUrl);

  const page2 = await context.newPage();
  page2.on("framenavigated", (frame) => {
    if (frame === page2.mainFrame()) {
      console.log("   [nav2]", frame.url());
    }
  });

  await page2.goto(hashLoginUrl, { waitUntil: "networkidle" });
  // Should auto-login since we already have a Keycloak session
  await page2.waitForTimeout(5000);
  await page2.screenshot({ path: `${SCREENSHOTS}/direct-04-hash-result.png` });
  console.log("   Final URL:", page2.url());

  if (page2.url().includes("token=")) {
    console.log("   TOKEN FOUND in hash return_to URL");
  } else {
    console.log("   NO TOKEN in hash return_to URL");
  }

  console.log("\n7. Redirect chain summary:");
  redirects.forEach((url, i) => console.log(`   ${i}: ${url}`));

  console.log("\nDone.");
  await browser.close();
})();
