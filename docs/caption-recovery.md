# Caption recovery

The production failure on submission 593 exposed a gap between model validation
and excerpt validation: a response at second 1019 (16:59) passed the video's
4463-second bound even though its supplied excerpt ended at second 893 (14:53).
The excerpt check then terminated the job outside the model retry loop.

## Response contract and retry limits

Each excerpt now passes its inclusive minimum and maximum seconds to the shared
timestamp decoder inside GeminiClient. The same bounds are sent in the response
schema. Gemini supports numeric minimum and maximum constraints, but application
validation remains authoritative; see Google's [structured-output documentation](https://ai.google.dev/gemini-api/docs/generate-content/structured-output).

An invalid response gets a fresh request with a short, trusted correction stating
the allowed range. Raw model output is not copied into that instruction. Each
request has at most three attempts; provider Retry-After sleeps are capped at
30 seconds. Every dispatched attempt claims work and retains its usage and cost,
including rejected responses. Budget denials cannot dispatch a correction.
Exhausted validation failures stay terminal instead of multiplying the model
retry allowance through automatic job retries. Transport and transient HTTP
failures retain their existing job retry policy.

The public API and UI distinguish out-of-excerpt chapters from other invalid
chapter data, including the older generic error stored for submission 593. They
do not claim that raw provider output is saved for debugging.

## Durable progress

The additive migration `20260910030000` creates `caption_checkpoints`. It stores
only validated chapter candidates and model identifiers, with a SHA-256 digest
of the generation inputs. It does not store the transcript or provider response.
There is at most one checkpoint per submission and chunk index; normal input
limits cap a submission at 24 chunks. Deleting a submission cascades to its
checkpoints.

Successful chunks are saved before moving on. A retry downloads the current
captions and reuses a checkpoint only when the submission, chunk position,
prompt/evidence, bounds, configured model, thinking level, and response schema
match. Stored chapter data is validated again before reuse. Changed or corrupted
entries are regenerated and replaced. Earlier billed requests remain in the
attempt ledger; a cache hit creates no new provider request or charge.

A process kill between receiving a provider response and saving its checkpoint
can still require repeating that one request. Missing usage remains unknown.
Completed prior excerpts survive a kill, and their reuse does not depend on an
in-memory cache. Checkpoints do not provide semantic validation of chapter titles.

## Verification

The offline production baseline includes a synthetic regression preserving the
observed 0–893/1019 timing mismatch and five-chunk layout. It verifies correction,
all-excerpt completion, final distillation, and accounting of the rejected reply.
Tests additionally cover exhausted retries, restarted clocks, hard worker kills,
late failures, changed evidence, corrupted checkpoints, and budget denial.

Apply migrations before workers start. The production Docker entrypoint already
does this; use the [Railway deployment flow](deployment.md).
