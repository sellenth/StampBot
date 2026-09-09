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

## Durable submissions

Submissions are saved with an Oban job in the same PostgreSQL transaction. The
web app, extension, and bookmarklet show saved job progress and can reconnect
without restarting generation. Run migrations before starting the updated app:

```sh
mix deps.get
mix ecto.migrate
```

The Docker entrypoint already runs release migrations before application startup.
See [the milestone implementation notes](docs/milestone-one.md) for recovery,
checkpoint, retry, and rollout behavior. Elixir 1.15+ is required.

## Validation and evaluation

```sh
MIX_ENV=test mix test
npm run test:js
npm run test:submission-ui
MIX_ENV=test mix run --no-start evals/production_baseline.exs
```

The production baseline uses deterministic fixtures, rolls back its database
writes, and makes no provider calls. See [evaluation instructions](evals/README.md)
and [the recorded baseline](evals/results/production_baseline_2026-09-09.md).
These checks do not measure live YouTube availability or chapter quality.

The old top-YouTube model comparison below bypasses production routing and makes
paid model calls. It is retained as a historical experiment, not the baseline:

```sh
MIX_ENV=test mix run --no-start evals/top_youtube_trending.exs
```

## Security and measurement

See [the second milestone](docs/milestone-two.md) for processing limits,
operator-approved publication, trusted-proxy configuration, and rollout settings.
Public submissions generate results; system-account comment posting requires
operator approval by default. Automatic posting is an explicit deployment choice.

```sh
# Read-only operational summary; no workers or provider calls are started.
MIX_ENV=prod mix stampbot.operations --hours 24 --json

# Export a private, frozen review cohort; no model calls are made.
MIX_ENV=prod mix stampbot.export_eval_cohort --output tmp/evals/cohort-2026-09-09
```

Run these commands against the deliberately selected database environment.
The [evaluation guide](evals/README.md) explains offline regression checks and
controlled live runs; [the next review](docs/next-review.md) lists remaining work.
