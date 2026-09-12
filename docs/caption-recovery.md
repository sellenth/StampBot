# Caption recovery

## Caption access and direct-video rescue

Caption acquisition first runs anonymously, preferring human subtitles and then
automatic captions. A bot or login challenge stops that extraction immediately;
when configured cookies exist, one authenticated extraction requests both types.
Missing captions, rate limits, unavailable videos, and runtime failures do not
trigger repeated cookie attempts. Each attempt records its access mode. Bot
challenges and invalid credentials now have separate failure categories.

Downloader calls ignore machine-specific config, forbid playlist processing,
use the configured caption language (English by default), and bound socket waits
to 15 seconds with one network retry and one extractor retry. The existing
30-minute worker timeout remains the overall job limit.

Videos up to 20 minutes still start with direct video analysis. Longer videos
still prefer captions. When caption acquisition fails, a video with a known
duration above 20 minutes and at most 60 minutes can use direct Gemini analysis
at low media resolution. That rescue gets at most two model attempts per job
run, retains request accounting and timestamp validation, and cannot fall back
into captions again. Existing job retry limits apply only to transient provider
failures; request allowances, cumulative spending limits, and publication policy
remain in force. Dollar allowances are conservative reservations, not a provider
billing guarantee.

Unknown durations, videos over an hour, unavailable videos, budget/input denials,
and caption summarization/validation failures do not trigger this rescue.
Successful caption metadata is retained across generation checkpoints.
This improves recovery options but does not guarantee YouTube or Gemini access.

The image bundles checksum-verified yt-dlp 2026.08.19, matching the version
observed in production before this rollout. A rate-limited startup self-update
therefore retains that version instead of reverting to the older July binary.

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

Live verification also caught a correction-request encoding defect: atom and
string keys produced two `systemInstruction` fields. Corrections now extend the
existing instruction, and strict JSON encoding rejects duplicate serialized keys.
A wire-format regression covers text, video, and an omitted initial instruction.
Out-of-order responses have a distinct bounded failure category in the ledger.

The subsequent live retry showed valid chapter pairs arriving out of order on
every attempt (for example, second 772 followed by second 101). Provider decoding
now sorts validated integer-time/title pairs before rendering, without changing
times, discarding entries, or asking the model to sort them again. Duplicate
times, out-of-range chapters, malformed fields, and incomplete provider responses
still fail validation. Stored checkpoints must already be in canonical order.
An additional five-excerpt regression covers ordering in both generation and
distillation, verifies no correction requests are needed, and checks checkpoint
reuse. Sorting does not verify the factual accuracy of a chapter title.

Apply migrations before workers start. The production Docker entrypoint already
does this; use the [Railway deployment flow](deployment.md).
