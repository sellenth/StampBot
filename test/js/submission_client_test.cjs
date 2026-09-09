const test = require('node:test');
const assert = require('node:assert/strict');
const SubmissionClient = require('../../priv/static/js/submission-client.js');

function setup(responses, options = {}) {
  const states = [];
  const requests = [];
  const delays = [];
  let elapsed = 0;
  const client = new SubmissionClient({
    endpoint: 'https://stamp-bot.com/api/gemini',
    baseUrl: 'https://stamp-bot.com/extension',
    onState: state => states.push(state),
    now: () => elapsed,
    sleep: async ms => { delays.push(ms); elapsed += ms; },
    fetch: async (url, request) => {
      requests.push({ url, method: request.method || 'GET' });
      const response = responses.shift();
      assert.ok(response, 'Unexpected additional request');
      if (response instanceof Error) throw response;
      return { ok: response.code >= 200 && response.code < 300, status: response.code, json: async () => response.data };
    },
    ...options
  });
  return { client, states, requests, delays };
}
const processing = { code: 200, data: { status: 'processing', phase: 'queued' } };
const accepted = { code: 202, data: { status: 'processing', timestamp_id: 42, status_url: '/api/submissions/42' } };
const complete = { code: 200, data: { status: 'success', response: '0:00 Intro' } };

test('202 remains processing until the durable submission completes', async () => {
  const { client, states, requests, delays } = setup([accepted, processing, complete]);
  await client.submit({ url: 'https://youtu.be/abc123xyz89' });
  assert.deepEqual(states.map(state => state.status), ['submitting', 'processing', 'processing', 'success']);
  assert.equal(states.at(-1).response, '0:00 Intro');
  assert.deepEqual(requests.map(request => request.method), ['POST', 'GET', 'GET']);
  assert.equal(requests[1].url, 'https://stamp-bot.com/api/submissions/42');
  assert.deepEqual(delays, [2000]);
});

test('a cached ready submission does not start polling', async () => {
  const { client, states, requests } = setup([complete]);
  await client.submit({ url: 'https://youtu.be/abc123xyz89' });
  assert.deepEqual(states.map(state => state.status), ['submitting', 'success']);
  assert.equal(requests.length, 1);
});

test('reopening resumes a saved ID with no new submission', async () => {
  const { client, states, requests } = setup([complete]);
  await client.watch({ timestamp_id: '42' });
  assert.equal(requests[0].method, 'GET');
  assert.equal(states.at(-1).status, 'success');
});

test('failed processing is reported as an error rather than success', async () => {
  const { client, states } = setup([accepted, { code: 200, data: { status: 'error', message: 'Video unavailable' } }]);
  await client.submit({ url: 'https://youtu.be/abc123xyz89' });
  assert.equal(states.at(-1).status, 'error');
  assert.equal(states.at(-1).message, 'Video unavailable');
  assert.equal(states.at(-1).timestamp_id, '42');
});

test('temporary failures recover without resubmitting', async () => {
  const { client, states, requests } = setup([
    { code: 503, data: {} }, new TypeError('Network unavailable'), complete
  ]);
  await client.watch({ timestamp_id: '42' });
  assert.equal(states.at(-1).status, 'success');
  assert.equal(requests.length, 3);
  assert.ok(requests.every(request => request.method === 'GET'));
});

test('repeated network failures pause and retain the resumable ID', async () => {
  const { client, states, requests } = setup(Array.from({ length: 5 }, () => new TypeError('Offline')));
  await client.watch({ timestamp_id: '42' });
  assert.equal(requests.length, 5);
  assert.equal(states.at(-1).status, 'paused');
  assert.equal(states.at(-1).timestamp_id, '42');
});

test('polling has a time limit when processing never finishes', async () => {
  const { client, states, requests } = setup(Array(10).fill(processing), { maxWaitMs: 3000 });
  await client.watch({ timestamp_id: '42' });
  assert.equal(requests.length, 2);
  assert.equal(states.at(-1).status, 'paused');
});

test('status URLs cannot redirect polling to another origin', async () => {
  const { client, states, requests } = setup([]);
  await client.watch({ timestamp_id: '42', status_url: 'https://other.example/api/submissions/42' });
  assert.equal(requests.length, 0);
  assert.equal(states.at(-1).status, 'error');
});

test('closing the client prevents late responses from changing the UI', async () => {
  let resolve;
  const { client, states } = setup([], { fetch: () => new Promise(done => { resolve = done; }) });
  const watching = client.watch({ timestamp_id: '42' });
  client.stop();
  resolve({ ok: true, status: 200, json: async () => complete.data });
  await watching;
  assert.deepEqual(states.map(state => state.status), ['processing']);
});
