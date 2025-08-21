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
});

// Optional: Add context menu for right-click functionality
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'generate-timestamps',
    title: 'Generate Timestamps with Drag-n-Stamp',
    contexts: ['page', 'video'],
    documentUrlPatterns: [
      'https://www.youtube.com/*',
      'https://youtube.com/*'
    ]
  });
});

// Handle context menu clicks
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'generate-timestamps') {
    // Open the popup programmatically (note: this requires user interaction)
    chrome.action.openPopup();
  }
});