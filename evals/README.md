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
persisted generation without duplicate video/caption requests. It also covers
`UNWATCHED`, refusals with parseable JSON, `MAX_TOKENS`, failure after five
completed caption chunks, oversized transcripts rejected before model dispatch,
missing provider usage, an untrusted instruction marker, and HTML script-context
encoding, and a request allowance that blocks distillation before HTTP dispatch
while retaining the primary result. Separate
[URL cases](fixtures/url_contract.json) check watch, reordered query, shortened,
mobile, Shorts, live, and embed links as well as invalid hosts and IDs.

For continuous speech, every synthetic segment carries an evidence marker. The
harness verifies that **every marker reaches an actual caption prompt**, including
the last segment, and that late timestamps survive chunk merging and distillation.
This detects the old prefix-truncation and continuous-caption-collapse failure
without a paid model call. The offline model chooses first and last supplied
timecodes; it does not attempt semantic understanding. Simulated 429s and invalid
JSON go through the actual Gemini retry/validation code. Every simulated HTTP
request must have a matching durable request ledger row; usage from rejected
responses survives validation, and absent usage remains unknown. The report
separates acquisition evidence, pipeline completion, timestamp format/bounds, and
human chapter quality. `UNWATCHED` is explicitly unusable. The instruction-marker
case checks the system/user data boundary only; it does not prove model resistance
to prompt injection. Rendering uses an in-memory static page and executes no script.

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
useful model-performance metrics; the report labels actual paid cost as zero and
semantic quality as unmeasured. Synthetic usage-based estimates are identified
separately. The oversized case briefly enables real work limits inside the
sequential fixture process, then restores test configuration.

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
environment settings. Only IDs in the selected cohort are accepted, one per
run; `--cohort PATH/manifest.json` selects an exported cohort instead of the
historical sample. Metadata is fetched again rather than assuming snapshot duration is current.
The real processor runs with publication disabled, in a local test transaction
that rolls back. The output is an **unreviewed observation**, not a pass verdict;
the attempt ledger includes retries, rejected model responses, and successful
chunks from failed runs. Only request rows contribute to the cost subtotal.
Missing usage or rates leave total cost unknown. The artifact includes a SHA-256
fingerprint of application source and dependency lockfile, stage/request records,
and generated content for review. This refresh's offline run does not execute live mode.

## Export actual failed and degraded submissions

This is a read-only engineering workflow, separate from a live model run:

```sh
MIX_ENV=prod mix stampbot.export_eval_cohort --output tmp/evals/cohort-2026-09-09
```

Run it only in the deliberately selected database environment. It loads normal
runtime configuration, starts Repo and its dependencies, and issues a bounded
read-only transaction. It does not start the application supervisor, Oban,
metadata acquisition, model calls, or publication. Do not prefix it with
`mix run` or `app.start`. No actual production export was performed by the
offline evaluation work.

The query selects actual failed rows and ready rows with absent/failed
distillation, recovered video fallback, or a legacy `UNWATCHED` marker. Active
processing rows are excluded. It reads the latest 10,000 matching rows by default
(`--scan-limit`, maximum 100,000), then selects up to 10 distinct video identities
per outcome/failure-category/duration/recorded-language stratum (`--per-stratum`). The manifest
reports if the scan limit was reached, which strata exist, and which have no
held-out examples. This is a failure-focused recovery sample, not an overall
production success-rate denominator.

Duplicate video identities collapse to one representative submission. A fixed
hash assigns every video to `tuning` or `held_out`; the default held-out share is
20% (`--held-out-percent` can be set when first creating the cohort). Membership
is stable across ordering and duplicate submissions. Freeze that configuration
and the manifest before prompt tuning; small strata may need more examples.

The task creates a **new private directory** containing `manifest.json` and a
blank `review.csv`, and refuses to replace an existing cohort. It exports canonical
video IDs, source submission IDs, and allowlisted historical outcome metadata.
It does not select or export user names, generated/source text, raw errors, full
processing context, credentials, or OAuth/cookie data. Keep the cohort private:
video identities can refer to unlisted submissions. Unknown language and failure
categories remain unknown rather than being guessed from free text.

An explicitly authorized single-video live run from that frozen manifest is:

```sh
STAMPBOT_EVAL_ALLOW_LIVE=1 MIX_ENV=test mix run --no-start \
  evals/production_baseline.exs --live \
  --cohort tmp/evals/cohort-2026-09-09/manifest.json --video VIDEO_ID \
  --output tmp/evals/run-VIDEO_ID.json
```

The live runner still requires an isolated local test database, disables
publication, enables real work limits for the scoped processor call, and rolls
back row writes. Run request/input limits apply. Because attempt and reservation
rows are rolled back, this does **not** enforce or measure a shared daily budget
across separate eval runs or against production spend. It does not run the cohort in bulk or
assign quality scores. Follow the [human review rubric](HUMAN_REVIEW.md) for source
evidence, factual support, chapter timing, coverage, safety, stable held-out
comparisons, and denominators. Acquisition, completion, and usable chapters must
be reported separately. Add healthy controls before claiming overall reliability.
