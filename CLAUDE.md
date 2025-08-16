# Drag-n-Stamp

Phoenix application with a YouTube-specific bookmarklet that sends video URLs and channel info to a backend service.

## Features

- **YouTube Video Bookmarklet**: JavaScript bookmarklet that validates YouTube URLs and extracts both channel names and usernames
- **API Endpoint**: `/api/receive-url` accepts POST requests with URL and username data
- **Gemini API Integration**: `/api/gemini` endpoint for YouTube video timestamp generation using Gemini 2.5 Flash
- **CORS Support**: Allows cross-origin requests from any website
- **Chrome Compatibility**: Copy-paste approach avoids URL encoding issues in Chrome
- **Dual Extraction**: Automatically scrapes both @username handles (from #channel-handle) and channel names using multiple DOM selectors
- **Logging**: Server logs all received URLs, usernames, and channel names for verification

## Architecture

```
lib/drag_n_stamp_web/
├── controllers/
│   ├── page_html/home.html.heex  # Homepage with bookmarklet
│   └── api_controller.ex         # API endpoint handler
├── plugs/
│   └── cors.ex                    # CORS middleware
└── router.ex                      # Routes configuration
```

## Development

```bash
# Start server (loads .env file automatically)
mix phx.server

# Test URL receive endpoint
curl -X POST http://localhost:4000/api/receive-url \
  -H "Content-Type: application/json" \
  -d '{"url": "https://youtube.com/watch?v=abc123", "username": "testuser"}'

# Test Gemini API endpoint for YouTube timestamps
curl -X POST http://localhost:4000/api/gemini \
  -H "Content-Type: application/json" \
  -d '{"channel_name": "YourChannelName", "username": "yourusername", "url": "https://www.youtube.com/watch?v=VIDEO_ID"}'

# Example response: 10 timestamps with 8-12 words each, formatted for YouTube descriptions
```

## API Endpoints

### `/api/receive-url` - URL Collection
- Accepts YouTube video URLs and channel usernames
- Used by the bookmarklet to send video data

### `/api/gemini` - Video Timestamp Generation
- **Parameters**: 
  - `channel_name`: YouTube channel name for personalization
  - `username`: YouTube channel username (@handle) for personalization
  - `url`: YouTube video URL for analysis
- **Response**: 10 timestamps with 8-12 words each, YouTube description format
- **Timeout**: 5 minutes for video processing
- **Model**: Gemini 2.5 Flash with video understanding

## Environment Setup

Create a `.env` file in the project root with your Gemini API key:
```
GEMINI_API_KEY=your_api_key_here
```

## Bookmarklet Configuration

Current endpoint: `http://localhost:4000/api/gemini`

- Only works on YouTube video pages (youtube.com, youtu.be, m.youtube.com)
- Chrome users: copy JavaScript code from textarea and paste as bookmark URL
- Firefox users: can drag-and-drop the bookmarklet button
- Extracts both @username handles (from #channel-handle) and channel names using multiple fallback DOM selectors
- Sends both username and channel_name to Gemini API for personalized timestamp generation

To change for production, modify the endpoint variable in the JavaScript code in `home.html.heex`.

## Deployment on Fly.io

This repository contains a ready‑to‑deploy configuration for hosting the Drag‑n‑Stamp service on [Fly.io](https://fly.io/).  The deployment is split into two environments—development and production—to mirror your local workflow and keep testing separate from real traffic.  These steps assume you have the [Fly CLI](https://fly.io/docs/hands-on/install-flyctl/) installed.  If you don’t, download the latest release for your platform and add it to your PATH.

### 1. Create and configure apps

1. **Log in**: Run `fly auth login` and follow the browser prompt to authenticate.  If you don’t already have an account, create one using your GitHub account.
2. **Initialize the dev app**: `fly apps create drag-n-stamp-dev` and select the `sjc` region (San Jose) when prompted.  Repeat for the production app by replacing `dev` with `prod`.
3. **Attach Postgres**: For each environment run:

   ```bash
   fly postgres create --name drag-n-stamp-dev-db --organization personal --region sjc --initial-cluster-size 1 --vm-size shared-cpu-1x
   fly postgres create --name drag-n-stamp-prod-db --organization personal --region sjc --initial-cluster-size 1 --vm-size shared-cpu-1x
   ```

   Enable daily backups with three‑day retention using `fly backup enable --app drag-n-stamp-dev-db --frequency 24h --retain 3` (and repeat for prod).

4. **Configure secrets**: Generate a secret key base (`mix phx.gen.secret`) and set it along with your Gemini API key:

   ```bash
   fly secrets set SECRET_KEY_BASE=your_generated_key GEMINI_API_KEY=your_gemini_key -a drag-n-stamp-dev
   fly secrets set SECRET_KEY_BASE=your_generated_key GEMINI_API_KEY=your_gemini_key -a drag-n-stamp-prod
   ```

5. **Set database URLs**: After the Postgres cluster is created, note the connection string shown in the CLI output.  Set it as a secret on each app:

   ```bash
   fly secrets set DATABASE_URL="postgres://postgres:<password>@drag-n-stamp-dev-db.flycast:5432/postgres" -a drag-n-stamp-dev
   fly secrets set DATABASE_URL="postgres://postgres:<password>@drag-n-stamp-prod-db.flycast:5432/postgres" -a drag-n-stamp-prod
   ```

### 2. Deploying

Both environments use the same source code and Dockerfile; only the `fly.*.toml` configuration differs.  A helper script in `scripts/deploy.sh` wraps the deployment command:

```bash
./scripts/deploy.sh dev   # deploys using fly.dev.toml
./scripts/deploy.sh prod  # deploys using fly.prod.toml
```

The script builds the release on Fly’s builders (`--remote-only`) and deploys the resulting image.  The first deployment will create a machine, apply the configuration, and set up HTTP listeners.  Subsequent deployments replace the machine with zero downtime.

### 3. Database migrations

After the first deployment and whenever your schema changes, run migrations on your Fly Postgres database.  Fly creates an SSH console for each machine.  To run migrations on dev:

```bash
fly ssh console -a drag-n-stamp-dev --command "bin/drag_n_stamp eval \"DragNStamp.Release.migrate()\""
```

Replace `drag-n-stamp-dev` with `drag-n-stamp-prod` when running against the production database.

### 4. Testing endpoints

Once deployed, the application will be available at `https://drag-n-stamp-dev.fly.dev` and `https://drag-n-stamp-prod.fly.dev`.  Verify the endpoints with `curl` or your browser:

```bash
curl -X POST https://drag-n-stamp-dev.fly.dev/api/receive-url \
  -H "Content-Type: application/json" \
  -d '{"url":"https://youtube.com/watch?v=abc123","username":"testuser"}'

curl -X POST https://drag-n-stamp-dev.fly.dev/api/gemini \
  -H "Content-Type: application/json" \
  -d '{"channel_name":"YourChannelName","username":"yourusername","url":"https://youtube.com/watch?v=VIDEO_ID"}'
```

Remember to update the bookmarklet endpoints in `home.html.heex` for each environment (`/api/gemini` should point to the appropriate fly.dev domain).

### 5. Developer experience

* **Scripted deploys**: The `scripts/deploy.sh` script abstracts away the `fly deploy` flags and selects the appropriate TOML file based on the argument.
* **Environment switching**: Use `fly apps list` to view your apps and `fly config save` to inspect the current config.  Deploy with the correct TOML file to target dev or prod.
* **Monitoring and logs**: Fly provides simple health checks and log streaming by default.  View logs with `fly logs -a drag-n-stamp-dev`.  Health status is available on the app dashboard.

### 6. Costs

Fly.io offers a generous free tier.  The development environment (1 shared‑CPU machine and a small Postgres instance) should cost roughly **$5–10 per month**, while the production environment (with similar resources) will be **$10–20 per month** depending on usage.  Daily backups are included in the Postgres pricing and retained for three days as configured above.

## GitHub

Repository: https://github.com/sellenth/drag-n-stamp