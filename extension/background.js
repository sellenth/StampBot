// Background service worker
// Handles communication between content scripts and popup

// Listen for URL changes from content script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'URL_CHANGED') {
    // Store the latest video data
    chrome.storage.local.set({ 
      lastVideoData: message.data,
      lastVideoUrl: message.url 
    });
  }
});

// Handle extension installation
chrome.runtime.onInstalled.addListener(() => {
  console.log('Drag-n-Stamp extension installed');
  
  // Set default storage values
  chrome.storage.local.get('username', (result) => {
    if (!result.username) {
      chrome.storage.local.set({ username: null });
    }
  });
  
  // Add context menu for right-click functionality
  try {
    chrome.contextMenus.create({
      id: 'generate-timestamps',
      title: 'Generate Timestamps with Drag-n-Stamp',
      contexts: ['page', 'video'],
      documentUrlPatterns: [
        'https://www.youtube.com/*',
        'https://youtube.com/*'
      ]
    });
  } catch (error) {
    console.log('Context menu creation failed:', error);
  }
});

// Handle context menu clicks
try {
  chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === 'generate-timestamps') {
      // Store context menu trigger info for popup to use
      chrome.storage.local.set({ 
        contextMenuTriggered: true,
        contextMenuUrl: tab.url,
        contextMenuTimestamp: Date.now()
      });
      
      // Note: chrome.action.openPopup() doesn't work from context menu in MV3
      // User needs to click the extension icon to open popup
    }
  });
} catch (error) {
  console.log('Context menu click handler failed:', error);
}