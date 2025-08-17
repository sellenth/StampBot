# Drag-n-Stamp

Phoenix app with YouTube bookmarklet for timestamp generation using Gemini API.

## Development

```bash
# Start with database proxy
./dev.sh

# Or manually:
mix phx.server
```

Environment: Create `.env` with `GEMINI_API_KEY=your_key`

## API Endpoints

- `/api/receive-url` - Collects YouTube URLs and usernames
- `/api/gemini` - Generates 10 timestamps for YouTube videos

## Deploy

```bash
./scripts/deploy.sh dev   # or prod
```

Apps: `drag-n-stamp-dev.fly.dev`, `drag-n-stamp-prod.fly.dev`