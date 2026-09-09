# Production pipeline baseline

Run the deterministic baseline before comparing models:

```sh
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix run --no-start evals/production_baseline.exs
```

The default run uses the local test database and rolls back each case's row
writes (PostgreSQL sequences may advance). It starts
only the repository and PubSub, calls the same
`DragNStamp.Submissions.Processor.process/2` used by the submission worker, and
disables publication. It does not load `.env`, start the job scheduler, download
media, contact model providers, or spend API credits. It refuses a non-test or
non-local database and refuses an already-started application supervisor.

`--list` lists fixtures without starting the database. `--case ID` selects one.
`--output PATH` changes the JSON report location (default:
`tmp/evals/production_baseline.json`). A failing contract exits with status 1.

## What the baseline measures

The processor's routing, fallback decisions, stage persistence, typed failures,
and distillation behavior are real. `CaptionFallback` uses its real transcript
chunking, prompts, output validation, and merge. `GeminiClient` builds real
requests, parses response envelopes, validates timestamps, and applies its retry
policy. Only metadata lookup, caption fetching, model HTTP transport, and retry
sleep are replaced with deterministic fixtures. The fixture key is a dummy value;
the model HTTP transport never invokes Finch's network request function.

The [case manifest](fixtures/production_baseline.json) covers short video,
short-link input, 90 minutes of continuous captions exceeding 60,000 characters,
multilingual captions, unknown duration, video failure followed by caption
recovery, rate-limit retry, missing captions, caption rate limiting, out-of-bounds
model output, failed distillation with usable primary output, and resuming a
persisted generation without duplicate video/caption requests. Separate
[URL cases](fixtures/url_contract.json) check watch, reordered query, shortened,
mobile, Shorts, live, and embed links as well as invalid hosts and IDs.

For continuous speech, every synthetic segment carries an evidence marker. The
harness verifies that **every marker reaches an actual caption prompt**, including
the last segment, and that late timestamps survive chunk merging and distillation.
This detects the old prefix-truncation and continuous-caption-collapse failure
without a paid model call. The offline model chooses first and last supplied
timecodes; it does not attempt semantic understanding. Simulated 429s and invalid
JSON go through the actual Gemini retry/validation code.

The URL identities are copied from the historical eval. Synthetic durations,
transcript text, access failures, and model responses **do not describe those
real videos**. Each database transaction is rolled back, so synthetic data is
never retained as a real result. The report contains no invented benchmark score:
pass/fail means the expected software contract held, including correctly handled
failures, rather than “this percentage of public videos now works.” On a generation
error, the processor returns the typed failure and retains the processing
checkpoint; the job worker owns retries and the terminal failed status.

This does not test the HTTP/UI submission contract, queue scheduling, restart
recovery, concurrent deduplication, real caption-provider availability, network
timeouts, or human chapter quality. Those need the focused application tests and
an explicitly authorized live evaluation. Offline duration and cost are not
useful model-performance metrics; the report labels cost as zero and semantic
quality as unmeasured.

## Explicit live runs

The [historical cohort](fixtures/historical_video_cohort.json) retains the five
known videos from the August 17 sample, with provenance and expected production
routes. It is not claimed to be current or representative. In particular, the
27-minute example enters **captions** under the retained 20-minute production
threshold; the old `top_youtube_trending.exs` called Gemini video directly for
every example, bypassing that decision. The old five-video result therefore
cannot establish production success rates.

Live mode requires both a command-line switch and a separate environment opt-in.
It may incur model charges and contact YouTube. Run it only when those actions
have been authorized, using credentials already available in the environment:

```sh
STAMPBOT_EVAL_ALLOW_LIVE=1 MIX_ENV=test mix run --no-start \
  evals/production_baseline.exs --live --video t2I_6p1TwfM
```

`GEMINI_API_KEY` must be set; production metadata/caption adapters use their usual
environment settings. Only IDs in the historical cohort are accepted, one per
run. Metadata is fetched again rather than assuming snapshot duration is current.
The real processor runs with publication disabled, in a local test transaction
that rolls back. The output is an **unreviewed observation**, not a pass verdict;
the retained-result cost estimate excludes failed/discarded attempts, including
successful chunks from failed pipeline runs. Missing usage or rates leave total
cost unknown. This refresh's offline run does not execute live mode.

Before making a reliability claim, extend the real cohort with actual failed
submissions and the missing strata listed in its manifest. Record source
availability at run time, language, duration, captions, route, failure category,
all-attempt cost (or explicitly unknown), and latency. Keep unavailable-source
cases separate from model-quality failures. Have a reviewer watch chapter
boundaries and check factual support, omitted important events, and unsupported
claims. Include the long continuous-caption cases, rather than only short
trending trailers. Compare the same source inputs and pipeline version across
model configurations, and keep a held-out set when tuning prompts.
