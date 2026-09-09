# First reliability milestone

The submission pipeline now lives in `DragNStamp.Submissions.Processor`, shared
by production workers and the evaluation harness. HTTP controllers no longer
perform video analysis or call themselves through HTTP.

## Acceptance and execution

1. Parse a supported YouTube URL into a canonical video ID and watch URL.
2. Acquire a PostgreSQL transaction advisory lock for that ID, reuse an existing
   result or create a timestamp, and insert its unique Oban job in the same
   transaction. Network and model calls happen after the transaction finishes.
3. Return the committed submission ID immediately. The existing `/api/gemini`
   route responds with HTTP 202 for processing, or 200 for cached ready results.
4. `GET /api/submissions/:id` returns the current status, processing phase, and
   output when ready. LiveView uses the same domain service and PubSub updates.
   The extension and bookmarklet persist the ID and poll this endpoint on reopen.
5. The worker saves generated candidates before distillation. If execution is
   interrupted after this checkpoint, the next attempt resumes distillation.
6. Completion and the initial publishing job commit atomically. Comment posting
   runs independently and cannot delay the ready result.

The old Erlang lock is removed. Canonical URL variants share acceptance locks
across application instances. Legacy duplicate rows are retained; lookup prefers
an existing ready result. Existing funding-cap and manual UNWATCHED-retry rules
remain in place. Resubmitting a failed record starts another job after its
previous job has finished; the brief cancellation-acknowledgement race returns
409 instead of accepting work that would never run.

## Retries and restart recovery

The submission queue has two workers per app instance. A job gets at most three
attempts, with Oban's backoff for transient network/rate-limit failures. Known
terminal acquisition failures finish as failed without automatic retries. Each
attempt has a 30-minute timeout.

Oban Lifeline rescues jobs stuck executing after 35 minutes, checked every
minute. This threshold deliberately exceeds the worker timeout to avoid
duplicate execution of a healthy long request. The maintenance worker also
reconciles terminal crashed jobs with their public failed state and queues legacy
processing records that have no job. Test mode disables automatic execution.

On the first production startup, this recovery also resumes the existing
`processing` backlog. Review its size before the rollout when estimating API
spend. The lifetime 1,000-record cap remains unchanged and is not a per-run
spending budget.

Publishing gets one automatic attempt because YouTube does not provide a
request idempotency key. Interrupted posting has an uncertain outcome and must
not be blindly retried. The commenter's atomic pending claim protects the
queued publisher and manual retry from posting concurrently.

## Caption handling

Caption cues merge only within a bounded elapsed interval, retaining a timecode
approximately every 15 seconds of continuous narration. The whole transcript is
processed in excerpts bounded by 60,000 characters and approximately 15 minutes;
the old prefix-only truncation is gone. Oversized individual cues retain their
original interval when split, so an individual source cue may span a longer
period without inventing timing precision.

Each model call uses the original video clock and validates output against both
the excerpt interval and the known video duration. When metadata has no duration,
the final caption end supplies a conservative output bound; this is recorded as
`transcript_end`, not asserted to be the video's actual duration. Distillation
receives the same bound.

The first milestone keeps the current model defaults and the existing 20-minute
video/caption routing threshold. Model or routing comparisons now have a shared
production baseline.

## Validation

Run from the repository root:

```sh
MIX_ENV=test mix test
npm run test:js
npm run test:submission-ui
MIX_ENV=test mix run --no-start evals/production_baseline.exs
```

The application tests cover transactional acceptance, canonical deduplication,
retry states, recovery, durable generation checkpoints, and API/UI contracts.
The JavaScript and mocked Chromium checks cover acceptance, closure, reopening,
polling, origin checks, and rendering generated output as text.

The [baseline report](../evals/results/production_baseline_2026-09-09.md) covers
real routing, prompts, validation, and caption preprocessing with synthetic
external IO. Its pass rate is a software regression result. Live source
availability, semantic quality, and production success rates remain unmeasured.

September 9 verification: 90 Elixir tests and 11 JavaScript tests passed; the
mocked Chromium submission/reopen checks passed; the offline baseline passed
12 production cases and 13 URL checks. Compilation with warnings treated as
errors and formatting checks for all changed Elixir/HEEx files passed. The
repository-wide formatter still reports existing formatting differences in
untouched files (including `youtube_api.ex` and the root layout).

## Remaining boundaries

- Checkpointing is currently between generation and distillation. A failed
  later caption excerpt can cause earlier excerpts to be processed again.
- If distillation fails, the validated primary candidates remain available;
  this degraded output may contain more chapters than a distilled list.
- Cost estimates are partial retained-result estimates. Invalid responses,
  superseded attempts, and previous failed runs are not fully accounted for.
- The downloader and YouTube URL access restrictions are unchanged. Durable
  jobs provide recovery, not access to unavailable media.
- Broader authorization, submission/retry budgets, telemetry export, semantic
  evaluation, and model upgrades belong to the next review.

See [the follow-on review](next-review.md) for the proposed next work.
