# StampBot

On a mission to watch the most YouTube ever.

## Gemini configuration

StampBot uses separate model tiers for video understanding and text-only caption
summarization/distillation. The production defaults are:

- `GEMINI_VIDEO_MODEL=gemini-3.7-flash`
- `GEMINI_VIDEO_THINKING_LEVEL=medium`
- `GEMINI_TEXT_MODEL=gemini-3.5-flash-lite`
- `GEMINI_TEXT_THINKING_LEVEL=low`

`GEMINI_API_KEY` is required. Model environment variables are optional and are
read at request time, which makes canary overrides possible without code changes.
Timestamp cards persist and display an estimated total API cost calculated from
the successful generation and distillation usage metadata. Pricing rates live in
the `:gemini_cost_rates` application config so they can be updated independently.

Run the current top-YouTube comparison without starting the database:

```sh
MIX_ENV=test mix run --no-start evals/top_youtube_trending.exs
```
