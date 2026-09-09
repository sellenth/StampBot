const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function setup() {
  const sent = [];
  const stored = [];
  const removed = [];
  const listeners = {};
  const iframe = {
    src: 'https://stamp-bot.com/extension',
    style: {},
    contentWindow: { postMessage: (message, origin) => sent.push({ message, origin }) },
    addEventListener: () => {}
  };
  const loading = { style: {} };
  const context = {
    URL, Date, console,
    document: {
      getElementById: id => id === 'app-frame' ? iframe : loading,
      addEventListener: (name, callback) => { listeners[name] = callback; }
    },
    window: {
      addEventListener: (name, callback) => { listeners[name] = callback; },
      matchMedia: () => ({ matches: false })
    },
    chrome: {
      runtime: {},
      tabs: {
        query: async () => [{ id: 1, url: 'https://www.youtube.com/watch?v=abc123xyz89' }],
        sendMessage: (_tab, _message, callback) => callback({ channelName: 'Example' })
      },
      storage: { local: {
        get: async () => ({ username: 'alice', pendingSubmission: { timestamp_id: '42' } }),
        set: async value => stored.push(value),
        remove: async value => removed.push(value)
      } }
    }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../extension/popup.js'), 'utf8'), context);
  return { sent, stored, removed, listeners, iframe };
}

test('popup ready handshake restores the saved submission on the current app origin', async () => {
  const { listeners, iframe, sent } = setup();
  await listeners.DOMContentLoaded();
  await listeners.message({ origin: 'https://stamp-bot.com', source: iframe.contentWindow, data: { type: 'EXTENSION_READY' } });
  const initialized = sent.find(event => event.message.type === 'EXTENSION_INIT');
  assert.ok(initialized);
  assert.equal(initialized.origin, 'https://stamp-bot.com');
  assert.equal(initialized.message.data.pendingSubmission.timestamp_id, '42');
  assert.equal(initialized.message.data.username, 'alice');
});

test('pending IDs persist only for messages from the expected iframe and exact origin', async () => {
  const { listeners, iframe, stored, removed } = setup();
  await listeners.DOMContentLoaded();
  const state = { type: 'SUBMISSION_STATE', pending: { timestamp_id: 43 } };
  await listeners.message({ origin: 'https://stamp-bot.com.attacker.example', source: iframe.contentWindow, data: state });
  await listeners.message({ origin: 'https://stamp-bot.com', source: {}, data: state });
  assert.equal(stored.length, 0);
  await listeners.message({ origin: 'https://stamp-bot.com', source: iframe.contentWindow, data: state });
  assert.equal(stored[0].pendingSubmission.timestamp_id, '43');
  await listeners.message({ origin: 'https://stamp-bot.com', source: iframe.contentWindow, data: { type: 'SUBMISSION_STATE', pending: null } });
  assert.equal(removed[0], 'pendingSubmission');
});
