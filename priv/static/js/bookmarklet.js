var pageUrl = new URL(window.location.href);
if (!['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'].includes(pageUrl.hostname)) {
  window.alert('Open a YouTube video to generate timestamps.');
  return;
}
if (window.__stampbotSubmissionClient) window.__stampbotSubmissionClient.stop();
var previous = document.getElementById('stampbot-submission-dialog');
if (previous) previous.remove();
var storageKey = 'stampbot-submission:' + (pageUrl.searchParams.get('v') || pageUrl.pathname);
var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
var overlay = document.createElement('div');
overlay.id = 'stampbot-submission-dialog';
overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:2147483647;display:flex;align-items:center;justify-content:center;font-family:system-ui,sans-serif';
var dialog = document.createElement('section');
dialog.setAttribute('role', 'dialog');
dialog.setAttribute('aria-modal', 'true');
dialog.setAttribute('aria-label', 'StampBot timestamps');
dialog.style.cssText = 'padding:24px;border-radius:12px;max-width:600px;width:90%;max-height:80vh;overflow:auto;background:' + (dark ? '#1a1a1a;color:white' : 'white;color:#111827');
var title = document.createElement('h2');
title.style.cssText = 'font-size:20px;margin:0 0 16px';
var content = document.createElement('pre');
content.style.cssText = 'white-space:pre-wrap;font:14px/1.6 system-ui,sans-serif';
var feed = document.createElement('a');
feed.href = new URL('/', apiEndpoint).href;
feed.target = '_blank';
feed.rel = 'noopener noreferrer';
feed.textContent = 'View all submissions';
feed.style.cssText = 'display:inline-block;color:#3b82f6;margin:16px 16px 0 0';
var resume = document.createElement('button');
resume.textContent = 'Check progress';
resume.hidden = true;
resume.style.cssText = 'padding:8px;margin:16px 16px 0 0';
var close = document.createElement('button');
close.textContent = 'Close';
close.style.cssText = 'padding:8px;margin-top:16px';
dialog.append(title, content, feed, resume, close);
overlay.appendChild(dialog);
document.body.appendChild(overlay);
var pending = null;
function save(value) {
  pending = value;
  try {
    if (value) localStorage.setItem(storageKey, JSON.stringify(value));
    else localStorage.removeItem(storageKey);
  } catch (_) {}
}
var client = new window.StampBotSubmissions({
  endpoint: apiEndpoint,
  onState: function (state) {
    resume.hidden = state.status !== 'paused';
    if (state.status === 'submitting') {
      title.textContent = 'Saving your submission...';
      content.textContent = 'Please keep this dialog open until your submission is saved.';
    } else if (state.status === 'processing' || state.status === 'paused') {
      save({ timestamp_id: state.timestamp_id });
      title.textContent = 'Submission saved';
      content.textContent = state.status === 'paused'
        ? 'Your submission is saved. Live updates are paused. Check progress or view the feed for its result.'
        : 'Generating timestamps. You can close this dialog; click the bookmark again on this video to resume updates.';
    } else if (state.status === 'success') {
      save(null);
      title.textContent = 'Timestamps generated';
      content.textContent = state.response || '';
    } else if (state.status === 'error') {
      if (state.timestamp_id) save(null);
      title.textContent = 'Unable to process';
      content.textContent = state.message || 'Please check the feed or try again.';
    }
  }
});
window.__stampbotSubmissionClient = client;
close.onclick = function () { client.stop(); overlay.remove(); };
resume.onclick = function () { if (pending) client.watch(pending); };
try { pending = JSON.parse(localStorage.getItem(storageKey)); } catch (_) {}
if (pending && /^\d+$/.test(String(pending.timestamp_id || ''))) {
  client.watch(pending);
} else {
  var channel = document.querySelector('#channel-name a');
  client.submit({ url: pageUrl.href, channel_name: channel ? channel.textContent.trim() : 'anonymous' });
}
