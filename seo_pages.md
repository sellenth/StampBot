# Static SEO Timestamp Pages

## Proposed Work Items
- Catalog required metadata for each timestamp record (video title, channel, thumbnail, duration, chapters).
- Extend data pipeline to normalize timestamp content into reusable chapter entries.
- Build a Mix task that renders per-timestamp static pages into `priv/static/seo/`.
- Create a shared template/stylesheet for the static pages with meta tags, JSON-LD, and structured content blocks.
- Wire sitemap generation to include the new static pages and set canonical URLs.
- Surface internal links from the feed/dashboard to the static pages once generated.
- Implement backfill tooling to regenerate pages and metadata for existing timestamps.
- Add automated tests covering data extraction, page rendering, and sitemap entries.
