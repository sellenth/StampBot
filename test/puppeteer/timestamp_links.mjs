import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import puppeteer from 'puppeteer';

const source = await readFile(new URL('../../assets/js/clickable_timestamps.mjs', import.meta.url), 'utf8');
const browser = await puppeteer.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.setContent('<pre id="chapters"></pre>');
  await page.addScriptTag({ type: 'module', content: source + '\nwindow.linkifyTimestampElement = linkifyTimestampElement;' });
  await page.waitForFunction(() => typeof window.linkifyTimestampElement === 'function');
  const text = '59:26 Earlier\n1:03:48 First hour chapter\n1:07:52 Next\n1:12:08 Last\n1:03:48 Repeated\n0:00 <img src=x onerror="window.injected=true">\n1:60:00 Invalid\n1:03:48:12 Invalid\nMeet at 8:30 PM';
  const result = await page.evaluate(text => {
    const element = document.getElementById('chapters');
    element.dataset.videoUrl = 'https://www.youtube.com/watch?v=sLSTM9znQNs&t=5s';
    element.textContent = text;
    window.linkifyTimestampElement(element);
    window.linkifyTimestampElement(element); // LiveView updates must not nest links.
    return {
      text: element.textContent,
      links: Array.from(element.querySelectorAll('a'), a => ({ text: a.textContent, time: new URL(a.href).searchParams.get('t'), video: new URL(a.href).searchParams.get('v'), rel: a.rel })),
      images: element.querySelectorAll('img').length,
      nested: element.querySelectorAll('a a').length,
      injected: Boolean(window.injected),
    };
  }, text);
  assert.equal(result.text, text);
  assert.deepEqual(result.links.map(a => [a.text, a.time]), [['59:26', '3566s'], ['1:03:48', '3828s'], ['1:07:52', '4072s'], ['1:12:08', '4328s'], ['1:03:48', '3828s'], ['0:00', '0s']]);
  assert.ok(result.links.every(a => a.video === 'sLSTM9znQNs' && a.rel === 'noopener noreferrer'));
  assert.equal(result.images, 0);
  assert.equal(result.nested, 0);
  assert.equal(result.injected, false);
  const invalid = await page.evaluate(() => {
    const element = document.getElementById('chapters');
    element.dataset.videoUrl = 'javascript:alert(1)';
    window.linkifyTimestampElement(element);
    return { links: element.querySelectorAll('a').length, text: element.textContent };
  });
  assert.deepEqual(invalid, { links: 0, text });
  console.log('Passed: full hour links, correct seek times, repeated updates, literal untrusted text, invalid clocks and URLs.');
} finally {
  await browser.close();
}
