# Follow-on review: evaluations, observability, and security

The first milestone establishes durable execution and an offline regression
baseline. The next work should measure real outcomes and control the public
actions that consume API budget or publish through the bot's identity.

## Security priorities

These are findings from code review and local, non-network checks; no exploit
was submitted to the running service.

| Priority | Finding | Proposed change and acceptance check |
| --- | --- | --- |
| First | The SEO renderer embeds ordinary JSON inside a script element. A closing-script marker in untrusted channel data survives an in-memory render. This predates the milestone. | Use HTML-safe JSON encoding in `lib/drag_n_stamp/seo/static_page_renderer.ex`, add a script-context regression fixture, and review a scoped CSP. Generated titles, descriptions, and channel names must remain data in every rendering context. |
| First | Anonymous submissions and failed-record resubmissions can consume API work. The lifetime record cap does not bound retry spending. | Add per-caller and per-video rate limits, retry cooldowns, input/work limits, and an atomic daily budget reservation. Test concurrent requests at the budget boundary. Keep cached reads available. |
| First | Automatic publication and the public `retry_comment` event use the system's YouTube credentials without a caller publication policy. | Define who may publish, enforce that policy in the domain service, and apply account-wide posting limits. Test direct unauthorized requests as well as the UI. The milestone's atomic comment claim prevents races, but does not authorize callers. |
| Next | The downloader inherits the app environment, runs in the default-root container, and self-updates during startup. It lacks its own subprocess/output/file bounds. | Isolate caption acquisition with only the credentials it needs, a restricted runtime identity, private temporary files, bounded resources, and tested image updates. Verify that termination also cleans up the child process. |
| Next | Production database TLS uses `verify_none`. | Configure CA and hostname verification for the actual deployment and test both valid and invalid server identities. |

The milestone already canonicalizes supported YouTube URLs, checks the popup's
exact origin and frame source, constrains polling URLs, and renders generated
client output as text. Preserve the existing boundary that transcripts and
metadata are untrusted data and models have no arbitrary application tools.

## Evaluation tranche

Build a real cohort from actual failed submissions, stratified by length,
language, genre, caption availability, and source restrictions. Start with a
small measured run, then expand toward 100–200 cases. Record availability at
evaluation time; do not assume the historical trending sample is representative.
Keep development cases separate from held-out cases used for comparisons.

Report acquisition success, processing completion, and usable chapters
separately. Human review should check factual support, missing important
moments, and chapter-boundary accuracy. Report overall submission outcomes as
well as supported-source outcomes, so exclusions cannot conceal failures.

Add deterministic fixtures for UNWATCHED responses, malicious transcript
instructions, HTML/script markers, provider refusal or truncation, oversized
inputs, late caption-chunk failure, and uncertain publication. UNWATCHED can
still pass the timestamp schema today; it is not evidence of successful content
understanding. Existing publishing guards skip it.

Compare model and processing-mode changes independently on identical inputs.
The next Gemini experiment can compare 3.7 and 3.8, and static versus agentic
video processing, while retaining the current pipeline as the control. Select
changes using quality, acquisition coverage, latency, and cost per usable result.
The offline baseline does not provide those live model-performance measurements.

## Observability tranche

Persist an attempt record for each stage and caption chunk, linked to its
submission and job. Include provider request ID, model/prompt/schema versions,
start/end times, retry classification, and available token usage. Capture usage
before application validation can reject the response. Retain prior attempts
and completed chunks when later work fails; unknown cost must remain explicitly
unknown.

Export the existing telemetry and add queue age, stage latency, acquisition
failures, exhausted jobs, budget consumption, unknown costs, and uncertain
publishing outcomes. Keep submission IDs in traces and logs rather than
high-cardinality metric labels. Redact credentials and avoid recording complete
transcripts or provider payloads by default.

The first dashboard should answer: where submissions fail, which failures are
temporary, how long queued work waits, how much successful and unsuccessful
work costs, and whether any publishing attempts need reconciliation. Use those
measurements to set realistic service targets before changing model defaults.
