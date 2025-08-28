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
Change database_url to perform mix ecto.migrate

## API Endpoints

- `/api/receive-url` - Collects YouTube URLs and usernames
- `/api/gemini` - Generates 10 timestamps for YouTube videos

## Deploy

```bash
./scripts/deploy.sh dev   # or prod
```

Apps: `drag-n-stamp-dev.fly.dev`, `drag-n-stamp-prod.fly.dev`

## Note to agent
ASSUME THE PHOENIX SERVER IS ALREADY RUNNING, IT USUALLY IS. DON'T KILL IT TO START YOUR OWN
