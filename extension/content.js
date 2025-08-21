// Content script for YouTube pages
// Extracts video data and channel information

function getVideoData() {
  const data = {
    url: window.location.href,
    channelName: null,
    videoTitle: null,
    videoId: null
  };
  
  // Extract video ID from URL
  const urlParams = new URLSearchParams(window.location.search);
  data.videoId = urlParams.get('v');
  
  // Try multiple selectors to find channel name
  const channelSelectors = [
    '#channel-name a',
    '#text a.yt-simple-endpoint',
    '.ytd-channel-name a',
    'ytd-video-owner-renderer a.yt-formatted-string',
    '.owner-text a',
    'yt-formatted-string.ytd-channel-name a'
  ];
  
  for (const selector of channelSelectors) {
    const element = document.querySelector(selector);
    if (element && element.textContent) {
      data.channelName = element.textContent.trim();
      break;
    }
  }
  
  // Get video title
  const titleSelectors = [
    'h1.title.ytd-video-primary-info-renderer',
    'h1 yt-formatted-string.ytd-video-primary-info-renderer',
    '#title h1',
    'h1.watch-title-container'
  ];
  
  for (const selector of titleSelectors) {
    const element = document.querySelector(selector);
    if (element && element.textContent) {
      data.videoTitle = element.textContent.trim();
      break;
    }
  }
  
  return data;
}

// Listen for messages from popup
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.type === 'GET_VIDEO_DATA') {
    const videoData = getVideoData();
    sendResponse(videoData);
  }
  return true; // Keep message channel open for async response
});

// Auto-detect when video changes (for single-page navigation)
let lastUrl = location.href;
new MutationObserver(() => {
  const url = location.href;
  if (url !== lastUrl) {
    lastUrl = url;
    // Notify extension that URL changed
    chrome.runtime.sendMessage({
      type: 'URL_CHANGED',
      url: url,
      data: getVideoData()
    });
  }
}).observe(document, { subtree: true, childList: true });