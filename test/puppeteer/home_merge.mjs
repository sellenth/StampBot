import puppeteer from "puppeteer";

const baseUrl = process.env.BASE_URL || "http://localhost:4002";

async function assertSectionOrder(page) {
  const order = await page.evaluate(() => {
    const form = document.querySelector("#url-form");
    const feed = document.querySelector("#feed");

    if (!form || !feed) {
      return null;
    }

    const formTop = form.getBoundingClientRect().top;
    const feedTop = feed.getBoundingClientRect().top;

    return { formTop, feedTop };
  });

  if (!order) {
    throw new Error("Expected submit form and feed section to exist.");
  }

  if (!(order.formTop < order.feedTop)) {
    throw new Error(`Expected sections in order, got ${JSON.stringify(order)}`);
  }
}

async function assertTopControls(page) {
  await page.goto(`${baseUrl}/`, { waitUntil: "networkidle2" });
  await page.waitForSelector("#url-form");

  const controlsVisible = await page.evaluate(() => {
    const selectors = [
      'input[name="url"]',
      'input[name="username"]',
      '#url-form button[type="submit"]'
    ];

    return selectors.every((selector) => {
      const el = document.querySelector(selector);
      if (!el) return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
  });

  if (!controlsVisible) {
    throw new Error("Submit controls were not visible.");
  }

  await assertSectionOrder(page);
}

async function assertAnchors(page) {
  await page.goto(`${baseUrl}/#feed`, { waitUntil: "networkidle2" });
  await page.waitForSelector("#feed");

  const feedHash = await page.evaluate(() => window.location.hash);
  if (feedHash !== "#feed") {
    throw new Error(`Expected feed hash, got ${feedHash || "<empty>"}`);
  }
}

async function assertLegacyRedirects(page) {
  await page.goto(`${baseUrl}/feed`, { waitUntil: "networkidle2" });
  if (!page.url().endsWith("/#feed")) {
    throw new Error(`Expected /feed redirect to /#feed, got ${page.url()}`);
  }

  await page.goto(`${baseUrl}/leaderboard`, { waitUntil: "networkidle2" });
  if (!page.url().endsWith("/leaderboard")) {
    throw new Error(`Expected /leaderboard page, got ${page.url()}`);
  }

  await page.waitForSelector(".leaderboard-grid");

  const heading = await page.$eval("h1", (el) => el.textContent.trim());
  if (heading !== "Leaderboard") {
    throw new Error(`Expected leaderboard heading, got ${heading}`);
  }
}

async function assertResponsiveLayout(browser) {
  const desktop = await browser.newPage();
  await desktop.setViewport({ width: 1440, height: 1200 });
  await assertTopControls(desktop);
  await desktop.close();

  const mobile = await browser.newPage();
  await mobile.setViewport({ width: 390, height: 844, isMobile: true });
  await assertTopControls(mobile);
  await mobile.close();
}

const browser = await puppeteer.launch({ headless: "new" });

try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 1200 });

  await assertTopControls(page);
  await assertAnchors(page);
  await assertLegacyRedirects(page);
  await assertResponsiveLayout(browser);

  console.log("Puppeteer verification passed.");
} finally {
  await browser.close();
}
