// Get current tab info and pass to iframe
async function initializePopup() {
  const iframe = document.getElementById('app-frame');
  const loadingState = document.getElementById('loading-state');
  
  // Get current tab
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  
  // Check if we're on YouTube
  const isYouTube = tab.url && (
    tab.url.includes('youtube.com/watch') || 
    tab.url.includes('youtu.be/')
  );
  
  // Get stored username
  const { username } = await chrome.storage.local.get('username');
  
  // Wait for iframe to load
  iframe.addEventListener('load', () => {
    // Hide loading state
    loadingState.style.display = 'none';
    iframe.style.display = 'block';
    
    // Send initial data to iframe
    const message = {
      type: 'EXTENSION_INIT',
      data: {
        url: isYouTube ? tab.url : null,
        username: username || null,
        isYouTube: isYouTube
      }
    };
    
    iframe.contentWindow.postMessage(message, '*');
    
    // If on YouTube, get additional data from content script
    if (isYouTube) {
      chrome.tabs.sendMessage(tab.id, { type: 'GET_VIDEO_DATA' }, (response) => {
        if (response && response.channelName) {
          iframe.contentWindow.postMessage({
            type: 'VIDEO_DATA',
            data: response
          }, '*');
        }
      });
    }
  });
  
  // Listen for messages from iframe
  window.addEventListener('message', async (event) => {
    // Verify origin
    if (!event.origin.includes('drag-n-stamp')) return;
    
    switch (event.data.type) {
      case 'SAVE_USERNAME':
        await chrome.storage.local.set({ username: event.data.username });
        break;
        
      case 'GET_CURRENT_URL':
        iframe.contentWindow.postMessage({
          type: 'CURRENT_URL',
          data: { url: tab.url }
        }, '*');
        break;
        
      case 'CLOSE_POPUP':
        window.close();
        break;
    }
  });
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', initializePopup);