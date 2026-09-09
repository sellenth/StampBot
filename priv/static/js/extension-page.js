(function () {
  'use strict';
  const form = document.getElementById('timestamp-form');
  const submitButton = document.getElementById('submit-btn');
  const urlInput = document.getElementById('url');
  const usernameInput = document.getElementById('username');
  const pendingKey = 'stampbot-pending-submission';
  let parentOrigin = null;
  let pending = null;
  let channelName = 'anonymous';

  function stored(key) {
    try { return localStorage.getItem(key); } catch (_) { return null; }
  }

  function store(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch (_) {}
  }

  function tellParent(type, data) {
    if (parentOrigin) window.parent.postMessage(Object.assign({ type: type }, data), parentOrigin);
  }

  function remember(value) {
    pending = value;
    store(pendingKey, value ? JSON.stringify(value) : null);
    tellParent('SUBMISSION_STATE', { pending: value });
  }

  function showAlert(message, type) {
    const alert = document.createElement('div');
    alert.className = 'alert alert-' + type;
    alert.textContent = message;
    const alerts = document.getElementById('alerts');
    alerts.replaceChildren(alert);
  }

  function processingMessage(phase) {
    const phases = {
      queued: 'Submission saved. Waiting to process.',
      preparing: 'Submission saved. Preparing the video.',
      acquiring: 'Submission saved. Reading the video.',
      generating: 'Submission saved. Generating timestamps.',
      distilling: 'Submission saved. Finishing the timestamp list.',
      retrying: 'Processing hit a temporary problem. A retry is scheduled.',
      validating: 'Submission saved. Checking timestamps.'
    };
    return (phases[phase] || 'Submission saved. Processing timestamps.') + ' You can close this popup and reopen it to see progress.';
  }

  const client = new StampBotSubmissions({
    endpoint: form.dataset.apiEndpoint,
    onState: function (state) {
      submitButton.disabled = state.status === 'submitting';
      submitButton.textContent = state.status === 'submitting' ? 'Saving...' : 'Generate Timestamps';
      document.getElementById('resume-updates').hidden = state.status !== 'paused';
      if (state.status === 'submitting') {
        document.getElementById('result').hidden = true;
        showAlert('Saving your submission...', 'info');
      } else if (state.status === 'processing' || state.status === 'paused') {
        remember({ timestamp_id: state.timestamp_id });
        showAlert(state.status === 'paused' ? state.message : processingMessage(state.phase), 'info');
      } else if (state.status === 'success') {
        remember(null);
        document.getElementById('generated-timestamps').textContent = state.response || '';
        document.getElementById('result').hidden = false;
        showAlert('Timestamps generated successfully!', 'success');
      } else if (state.status === 'error') {
        if (state.timestamp_id) remember(null);
        showAlert(state.message || 'Could not confirm this submission. Please check the feed or try again.', 'error');
      }
    }
  });

  window.addEventListener('message', function (event) {
    if (event.source !== window.parent || !/^(chrome-extension|moz-extension):\/\/[a-zA-Z0-9-]+$/.test(event.origin)) return;
    if (!event.data || typeof event.data !== 'object') return;
    if (event.data.type === 'EXTENSION_PING') {
      window.parent.postMessage({ type: 'EXTENSION_READY' }, event.origin);
      return;
    }
    if (event.data.type === 'EXTENSION_INIT') {
      parentOrigin = event.origin;
      const data = event.data.data || {};
      document.body.classList.toggle('dark-mode', !!data.darkMode);
      if (typeof data.url === 'string') urlInput.value = data.url;
      if (typeof data.username === 'string') usernameInput.value = data.username;
      if (data.pendingSubmission && /^\d+$/.test(String(data.pendingSubmission.timestamp_id || ''))) {
        client.watch(data.pendingSubmission);
      } else if (pending) {
        tellParent('SUBMISSION_STATE', { pending: pending });
      }
    } else if (event.data.type === 'VIDEO_DATA' && event.data.data) {
      channelName = event.data.data.channelName || 'anonymous';
    }
  });

  form.addEventListener('submit', function (event) {
    event.preventDefault();
    const username = usernameInput.value.trim() || 'anonymous';
    store('drag-n-stamp-username', username);
    tellParent('SAVE_USERNAME', { username: username });
    client.submit({ url: urlInput.value.trim(), channel_name: channelName, submitter_username: username });
  });

  document.getElementById('resume-updates').addEventListener('click', function () {
    if (pending) client.watch(pending);
  });
  window.addEventListener('pagehide', function () { client.stop(); });
  usernameInput.value = stored('drag-n-stamp-username') || '';
  try {
    const saved = JSON.parse(stored(pendingKey));
    if (saved && /^\d+$/.test(String(saved.timestamp_id || ''))) client.watch(saved);
  } catch (_) {}
  if (window.parent !== window) window.parent.postMessage({ type: 'EXTENSION_READY' }, '*');
})();
