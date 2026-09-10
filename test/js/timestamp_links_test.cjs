const test = require('node:test');
const assert = require('node:assert/strict');

test('timestamp conversion handles the full hour form from production', async () => {
  const { timestampToSeconds } = await import('../../assets/js/clickable_timestamps.mjs');
  for (const [value, seconds] of [['0:00', 0], ['59:26', 3566], ['1:03:48', 3828], ['1:07:52', 4072], ['1:12:08', 4328], ['12:34:56', 45296]]) {
    assert.equal(timestampToSeconds(value), seconds);
  }
  for (const value of ['1:60:00', '1:03:99', '1:03:48:12', '1:03 PM', '', null, 'javascript:1:03']) {
    assert.equal(timestampToSeconds(value), null);
  }
});
