async function initializePopup() {
  const iframe = document.getElementById('app-frame');
  const loadingState = document.getElementById('loading-state');
  const appOrigin = new URL(iframe.src).origin;
  let initialData = null;
  let currentUrl = null;
  let tab = null;

  function send(type, data) {
    iframe.contentWindow.postMessage({ type: type, data: data }, appOrigin);
  }

  function initializeFrame() {
    if (!initialData) return;
    loadingState.style.display = 'none';
    iframe.style.display = 'block';
    send('EXTENSION_INIT', initialData);
    if (initialData.isYouTube && tab && tab.id) {
      chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEO_DATA' }, response => {
        if (chrome.runtime.lastError) return;
        if (response && response.channelName) send('VIDEO_DATA', response);
      });
    }
  }

  window.addEventListener('message', async event => {
    if (event.origin !== appOrigin || event.source !== iframe.contentWindow) return;
    if (!event.data || typeof event.data !== 'object') return;
    try {
      switch (event.data.type) {
        case 'EXTENSION_READY':
          initializeFrame();
          break;
        case 'SAVE_USERNAME':
          if (typeof event.data.username === 'string') {
            await chrome.storage.local.set({ username: event.data.username });
          }
          break;
        case 'SUBMISSION_STATE': {
          const pending = event.data.pending;
          if (pending === null) {
            await chrome.storage.local.remove('pendingSubmission');
          } else if (pending && /^\d+$/.test(String(pending.timestamp_id || ''))) {
            await chrome.storage.local.set({ pendingSubmission: { timestamp_id: String(pending.timestamp_id) } });
          }
          break;
        }
        case 'GET_CURRENT_URL':
          send('CURRENT_URL', { url: currentUrl });
          break;
        case 'CLOSE_POPUP':
          window.close();
          break;
      }
    } catch (error) {
      console.error('Could not save extension state:', error);
    }
  });

  iframe.addEventListener('load', () => send('EXTENSION_PING'));
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    tab = tabs[0];
    const saved = await chrome.storage.local.get([
      'contextMenuTriggered', 'contextMenuUrl', 'contextMenuTimestamp', 'username', 'pendingSubmission'
    ]);
    currentUrl = tab ? tab.url : null;
    if (saved.contextMenuTriggered && saved.contextMenuTimestamp && Date.now() - saved.contextMenuTimestamp < 5000) {
      currentUrl = saved.contextMenuUrl;
      await chrome.storage.local.remove(['contextMenuTriggered', 'contextMenuUrl', 'contextMenuTimestamp']);
    }
    let isYouTube = false;
    try {
      const url = new URL(currentUrl);
      isYouTube = ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'].includes(url.hostname);
    } catch (_) {}
    initialData = {
      url: isYouTube ? currentUrl : null,
      username: saved.username || null,
      isYouTube: isYouTube,
      darkMode: window.matchMedia('(prefers-color-scheme: dark)').matches,
      pendingSubmission: saved.pendingSubmission || null
    };
    send('EXTENSION_PING');
  } catch (error) {
    loadingState.textContent = 'Could not load StampBot. Please reopen the popup.';
    console.error('Could not initialize extension:', error);
  }
}

document.addEventListener('DOMContentLoaded', initializePopup);
