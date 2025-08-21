# Drag-n-Stamp Chrome Extension

Generate AI-powered timestamps for YouTube videos with a single click!

## Installation

### Developer Mode Installation (for testing)

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable "Developer mode" in the top right
3. Click "Load unpacked"
4. Select the `extension` directory from this project
5. The extension icon will appear in your toolbar

### Usage

1. Navigate to any YouTube video
2. Click the Drag-n-Stamp extension icon
3. The extension will:
   - Auto-detect the current YouTube video
   - Extract channel information
   - Allow you to generate timestamps with one click
4. Timestamps will be generated and displayed in the popup

## Features

- **Auto-detection**: Automatically detects YouTube videos and extracts metadata
- **Compact Interface**: Shows the web app in a scaled-down view perfect for extension popups
- **Username Persistence**: Saves your username for future use
- **Real-time Updates**: See processing status and results instantly
- **Cross-browser**: Works in Chrome, Edge, and other Chromium-based browsers

## Files

- `manifest.json` - Extension configuration
- `popup.html` - Main popup window
- `popup.js` - Popup logic and iframe communication
- `content.js` - YouTube page content extraction
- `background.js` - Service worker for background tasks
- `popup.css` - Styling for the popup
- `icons/` - Extension icons in various sizes

## Development

To modify the Phoenix app URL:
1. Edit `popup.html` and change the iframe `src` attribute
2. Update `manifest.json` host_permissions if using a different domain

## Testing

1. Make changes to extension files
2. Go to `chrome://extensions/`
3. Click the refresh button on the Drag-n-Stamp extension card
4. Test the changes

## Firefox Support

This extension is also compatible with Firefox:
1. Open Firefox and navigate to `about:debugging`
2. Click "This Firefox"
3. Click "Load Temporary Add-on"
4. Select the `manifest.json` file