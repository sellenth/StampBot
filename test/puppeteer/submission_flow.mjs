import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import puppeteer from 'puppeteer';

const clientSource = await readFile(new URL('../../priv/static/js/submission-client.js', import.meta.url), 'utf8');
const extensionSource = await readFile(new URL('../../priv/static/js/extension-page.js', import.meta.url), 'utf8');
const bookmarkletSource = await readFile(new URL('../../priv/static/js/bookmarklet.js', import.meta.url), 'utf8');
const extensionHtml = (await readFile(new URL('../../lib/drag_n_stamp_web/controllers/page_html/extension.html.heex', import.meta.url), 'utf8'))
  .replace('content={get_csrf_token()}', 'content="test"')
  .replace('data-api-endpoint={@api_endpoint}', 'data-api-endpoint="https://stamp-bot.com/api/gemini"')
  .replace(/src=\{~p"([^"]+)"\}/g, 'src="$1"');
const resultText = '0:00 <img src=x onerror="window.injected=true">';
let finished = false;
let posts = 0;
let statusReads = 0;

async function mockRequests(page) {
  await page.setRequestInterception(true);
  page.on('request', async request => {
    const url = new URL(request.url());
    const headers = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type' };
    if (request.method() === 'OPTIONS') return request.respond({ status: 204, headers });
    if (url.pathname === '/js/submission-client.js') return request.respond({ contentType: 'text/javascript', body: clientSource });
    if (url.pathname === '/js/extension-page.js') return request.respond({ contentType: 'text/javascript', body: extensionSource });
    if (url.hostname === 'stamp-bot.com' && url.pathname === '/extension') return request.respond({ contentType: 'text/html', body: extensionHtml });
    if (url.hostname === 'www.youtube.com') return request.respond({ contentType: 'text/html', body: '<div id="channel-name"><a>Example channel</a></div>' });
    if (url.pathname === '/api/gemini' && request.method() === 'POST') {
      posts += 1;
      return request.respond({ status: 202, headers, contentType: 'application/json', body: JSON.stringify({ status: 'processing', timestamp_id: 42, status_url: '/api/submissions/42' }) });
    }
    if (url.pathname === '/api/submissions/42') {
      statusReads += 1;
      return request.respond({ status: 200, headers, contentType: 'application/json', body: JSON.stringify(finished ? { status: 'success', response: resultText } : { status: 'processing', phase: 'queued' }) });
    }
    await request.respond({ status: 404, headers, body: 'This test blocks every unmocked request.' });
  });
}

const browser = await puppeteer.launch({ headless: true });
try {
  let page = await browser.newPage();
  await mockRequests(page);
  await page.goto('https://stamp-bot.com/extension');
  await page.type('#url', 'https://youtu.be/abc123xyz89');
  await page.click('#submit-btn');
  await page.waitForFunction(() => document.getElementById('alerts').textContent.includes('Submission saved.'));
  assert.equal(await page.$eval('#result', element => element.hidden), true);
  assert.equal(posts, 1);
  assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem('stampbot-pending-submission')).timestamp_id), '42');
  await page.close();

  finished = true;
  page = await browser.newPage();
  await mockRequests(page);
  await page.goto('https://stamp-bot.com/extension');
  await page.waitForFunction(() => !document.getElementById('result').hidden);
  assert.equal(posts, 1, 'Reopening the extension must resume without submitting again.');
  assert.equal(await page.$eval('#generated-timestamps', element => element.textContent), resultText);
  assert.equal(await page.$('#generated-timestamps img'), null, 'Generated output must remain text.');
  assert.equal(await page.evaluate(() => localStorage.getItem('stampbot-pending-submission')), null);
  await page.close();

  finished = false;
  page = await browser.newPage();
  await mockRequests(page);
  await page.goto('https://www.youtube.com/watch?v=abc123xyz89');
  const source = '(function(apiEndpoint){\n' + clientSource + '\n' + bookmarkletSource + '\n})("https://stamp-bot.com/api/gemini")';
  const bookmarkletUrl = 'javascript:' + encodeURIComponent(source);
  await page.evaluate(href => {
    const link = document.createElement('a');
    link.id = 'test-bookmarklet';
    link.href = href;
    link.textContent = 'StampBot';
    document.body.appendChild(link);
  }, bookmarkletUrl);
  await page.click('#test-bookmarklet');
  await page.waitForFunction(() => document.querySelector('#stampbot-submission-dialog h2')?.textContent === 'Submission saved');
  assert.equal(posts, 2);
  await page.evaluate(() => Array.from(document.querySelectorAll('#stampbot-submission-dialog button')).find(button => button.textContent === 'Close').click());
  finished = true;
  await page.click('#test-bookmarklet');
  await page.waitForFunction(() => document.querySelector('#stampbot-submission-dialog h2')?.textContent === 'Timestamps generated');
  assert.equal(posts, 2, 'The bookmarklet must resume a saved submission without another POST.');
  assert.equal(await page.$eval('#stampbot-submission-dialog pre', element => element.textContent), resultText);
  assert.equal(await page.$('#stampbot-submission-dialog img'), null);
  assert.ok(statusReads >= 4);
  console.log('Passed: extension acceptance/reopen, bookmarklet acceptance/reopen, safe generated text; all requests mocked.');
} finally {
  await browser.close();
}
