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

function createStampBotButton() {
  if (document.getElementById('stamp-bot-button')) {
    return; // Button already exists
  }

  const button = document.createElement('button');
  button.id = 'stamp-bot-button';
  button.innerHTML = `
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 2L13.09 8.26L22 9L13.09 9.74L12 16L10.91 9.74L2 9L10.91 8.26L12 2Z" fill="currentColor"/>
    </svg>
    Generate Timestamps
  `;
  
  // Style the button to match YouTube's design
  button.style.cssText = `
    display: flex;
    align-items: center;
    gap: 8px;
    height: 36px;
    padding: 0 16px;
    background: transparent;
    border: 1px solid var(--yt-spec-outline);
    border-radius: 18px;
    color: var(--yt-spec-text-primary);
    font: inherit;
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.1s ease;
    white-space: nowrap;
    margin-left: 8px;
  `;
  
  // Add hover effect
  button.addEventListener('mouseenter', () => {
    button.style.backgroundColor = 'var(--yt-spec-badge-chip-background)';
  });
  
  button.addEventListener('mouseleave', () => {
    button.style.backgroundColor = 'transparent';
  });
  
  // Add click handler
  button.addEventListener('click', async () => {
    const videoData = getVideoData();
    if (!videoData.videoId) {
      alert('Could not detect video. Please make sure you are on a YouTube video page.');
      return;
    }
    
    button.disabled = true;
    button.innerHTML = `
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
        <circle cx="12" cy="12" r="3" fill="currentColor">
          <animate attributeName="r" values="3;6;3" dur="1s" repeatCount="indefinite"/>
          <animate attributeName="opacity" values="1;0.3;1" dur="1s" repeatCount="indefinite"/>
        </circle>
      </svg>
      Generating...
    `;
    
    try {
      const response = await fetch('https://stamp-bot.com/api/gemini', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ url: videoData.url })
      });
      
      if (response.ok) {
        window.open('https://stamp-bot.com', '_blank');
      } else {
        throw new Error('Failed to generate timestamps');
      }
    } catch (error) {
      alert('Error generating timestamps. Please try again.');
    } finally {
      button.disabled = false;
      button.innerHTML = `
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path d="M12 2L13.09 8.26L22 9L13.09 9.74L12 16L10.91 9.74L2 9L10.91 8.26L12 2Z" fill="currentColor"/>
        </svg>
        Generate Timestamps
      `;
    }
  });
  
  return button;
}

function injectStampBotButton() {
  // Wait for the subscribe button area to load
  const subscribeSelectors = [
    '#subscribe-button-shape',
    'ytd-subscribe-button-renderer',
    '#subscribe-button',
    '.ytd-subscribe-button-renderer'
  ];
  
  for (const selector of subscribeSelectors) {
    const subscribeElement = document.querySelector(selector);
    if (subscribeElement) {
      const container = subscribeElement.closest('#top-row') || 
                      subscribeElement.closest('.ytd-video-owner-renderer') ||
                      subscribeElement.parentElement;
      
      if (container && !document.getElementById('stamp-bot-button')) {
        const stampButton = createStampBotButton();
        
        // Find the best insertion point
        const actionsContainer = container.querySelector('#actions') || container;
        if (actionsContainer) {
          actionsContainer.appendChild(stampButton);
        } else {
          container.appendChild(stampButton);
        }
        break;
      }
    }
  }
}

// Listen for messages from popup
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.type === 'GET_VIDEO_DATA') {
    const videoData = getVideoData();
    sendResponse(videoData);
  }
  return true; // Keep message channel open for async response
});

// Initialize button injection
function initializeExtension() {
  // Try to inject button immediately
  injectStampBotButton();
  
  // Set up observer to inject button when page changes
  const observer = new MutationObserver(() => {
    injectStampBotButton();
  });
  
  observer.observe(document.body, { 
    childList: true, 
    subtree: true 
  });
  
  // Also try after a short delay for slow-loading elements
  setTimeout(injectStampBotButton, 1000);
  setTimeout(injectStampBotButton, 3000);
}

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
    
    // Re-inject button on page change
    setTimeout(injectStampBotButton, 500);
  }
}).observe(document, { subtree: true, childList: true });

// Initialize when script loads
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initializeExtension);
} else {
  initializeExtension();
}