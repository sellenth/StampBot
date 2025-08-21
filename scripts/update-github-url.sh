#!/bin/bash

# Script to update GitHub URLs in the More Info page
# Usage: ./update-github-url.sh username/repo-name

if [ -z "$1" ]; then
    echo "Usage: $0 username/repo-name"
    echo "Example: $0 myusername/drag-n-stamp"
    exit 1
fi

REPO="$1"
FILE="lib/drag_n_stamp_web/live/more_info_live.html.heex"

echo "Updating GitHub URLs to use repository: $REPO"

# Update download URL
sed -i.bak "s|https://github.com/yourusername/drag-n-stamp|https://github.com/$REPO|g" "$FILE"

# Remove backup file
rm -f "${FILE}.bak"

echo "✅ Updated GitHub URLs in $FILE"
echo "📋 Don't forget to:"
echo "   1. Push changes to trigger the GitHub Action"
echo "   2. Verify the release is created automatically"
echo "   3. Test the download link works"