# Security and measurement milestone

The second milestone puts public processing and system-account publication behind
explicit policies, and records the work needed to evaluate reliability and cost.
The Gemini model defaults and the 20-minute video/caption routing policy stay the
same so future model experiments have a stable control.

## Processing limits

`DragNStamp.Submissions` accepts a new run, its work reservation, and its Oban job
in one database transaction. Canonical duplicates and existing ready results do
not reserve work again. Failed resubmissions and the one-time UNWATCHED retry obey
the same caller, video, and daily limits. A rejected retry rolls back its reset,
so it cannot erase the previous result or consume the one-time retry flag.

Before every Gemini request, including retries, the processor must present a
reservation linked to its submission. Missing context fails closed. A brief
PostgreSQL advisory lock serializes budget claims across app instances; the lock
ends before network IO. Legacy queued work obtains a reservation before execution.

Default limits are configurable through `:work_budget`:

| Limit | Default |
| --- | --- |
| New runs per caller in a rolling hour | 3 |
| Minimum interval between runs for the same video | 30 minutes |
| New runs per UTC day | 50 |
| Gemini requests per UTC day | 200 |
| Gemini requests per run, including retries | 32 |
| Video/transcript duration | 6 hours |
| Caption excerpts | 24 |
| Transcript bytes, including a per-cue overhead allowance | 2,000,000 |
| Encoded model request bytes | 262,144 |
| Requested maximum output tokens | 8,192 |
| API request body | 16 KiB |
| Submitted name | 200 characters, at most 800 bytes |

The existing 1,000-record funding cap also applies. The status endpoint and ready
cache lookups remain available after a processing budget is exhausted. Admission
limits return HTTP 429 with a safe reason and `Retry-After`; generation limits
become visible terminal processing failures.

### Dollar allowances and measured costs

Each accepted run initially reserves a configurable **$1.50 allowance** against
a **$25 UTC-day allowance budget**. Each video request consumes $1.50 of allowance;
each text request consumes $0.50. Additional requests atomically reserve any
shortfall. Failed, unknown, or interrupted requests never refund their allowance.
Unused prepaid allowance expires at UTC midnight; later work charges the new day.
The initial reservation alone can reach the allowance budget before the independent
50-run ceiling; source failures keep their reservation as well.

These amounts are conservative operator-configured allocations, **not a provider
invoice guarantee**. They are separate from measured usage-based estimates. The
request/input/concurrency limits are application-enforced bounds; a model or
pricing change requires review of both configured prices and allowances.

Deployment overrides include `STAMPBOT_CALLER_HOURLY_LIMIT`,
`STAMPBOT_VIDEO_COOLDOWN_SECONDS`, `STAMPBOT_DAILY_SUBMISSION_LIMIT`,
`STAMPBOT_DAILY_REQUEST_LIMIT`, `STAMPBOT_RUN_REQUEST_LIMIT`,
`STAMPBOT_DAILY_BUDGET_MICROUSD`, `STAMPBOT_INITIAL_ALLOWANCE_MICROUSD`,
`STAMPBOT_VIDEO_REQUEST_MICROUSD`, and `STAMPBOT_TEXT_REQUEST_MICROUSD`.
Dollar values use millionths of a US dollar; all overrides must be positive integers.

### Caller identity behind a proxy

Caller buckets are HMACs of the transport client address, using the application's
secret key base. Raw IP addresses are not stored in the work reservation table.
IPv6 addresses share a /64 bucket. A username, JSON field, or untrusted forwarding
header cannot choose a caller bucket.

Forwarded addresses are used only with an explicit `:trusted_proxy_cidrs` allowlist
(`STAMPBOT_TRUSTED_PROXY_CIDRS`, a comma-separated list).
The API and LiveView apply the same chain validation. Without a verified proxy
configuration, the conservative fallback is the transport peer; users behind a
shared proxy can therefore share a rate limit. Configure the actual ingress path
before rollout, rather than broadly trusting arbitrary private networks.

For Fly HTTP ingress, the rightmost X-Forwarded-For entry can be the application's
public address, so both that address and the actual ingress peer must be accounted
for in the allowlist. This follows [Fly's request-header documentation](https://fly.io/docs/networking/request-headers/).
No deployment network addresses were guessed or changed during this milestone.

## Publication and rendering

Publication now defaults to **operator approval**. Public submissions can generate
chapters; anonymous LiveView events and direct unprivileged Commenter calls cannot
post through the system's YouTube credentials. The public retry-comment button is
removed, and invoking its event directly is denied.

Set `STAMPBOT_OPERATOR_TOKEN` to a strong token of at least 32 bytes to enable the
operator endpoint. Review the generated submission, then enqueue its publication:

```sh
curl -X POST "https://YOUR_HOST/api/operator/submissions/SUBMISSION_ID/publish" \
  -H "Authorization: Bearer $STAMPBOT_OPERATOR_TOKEN"
```

Only the Authorization header authenticates an operator. Credentials are never
copied into job arguments. Jobs contain the source of authority and a digest of
the approved content. If the content changes before execution, that job cannot
publish it. Legacy jobs without explicit authority are rejected.

`STAMPBOT_AUTO_PUBLISH=true` explicitly enables automatic publication at both
queue insertion and execution. Turning it off also stops already-queued automatic
jobs. `STAMPBOT_DAILY_POST_LIMIT` defaults to 10 attempts per system account per UTC
day. A short account-level transaction reserves an attempt and claims the record
before the network call; concurrent jobs for different videos share the limit.
Failed and uncertain attempts count. Interrupted posting remains pending for
reconciliation rather than being blindly repeated.

JSON-LD now uses HTML-safe JSON encoding. A regression fixture verifies that
closing-script and comment markers in names, titles, descriptions, and chapters
cannot create an injected script element, while the JSON values round-trip.

## Attempts and operator reporting

The durable attempt ledger records runs, stages, caption chunks, and individual
provider requests, linked to submission, job, retry number, and run. It records
start/end times, duration, typed outcomes, model/prompt/schema versions, available
request IDs and token usage, and whether network dispatch occurred. Usage is
captured before response-content validation can reject an otherwise billed call.
Retries and completed chunks from later-failed runs remain in the ledger.

Missing usage or pricing remains unknown. Public status responses expose whether
accounting is complete; the feed labels a subtotal as “Known cost” when some
requests have unknown cost. Only request rows contribute to cost
subtotals, avoiding double-counting parent spans. A killed worker leaves visible
unfinished records; the next job attempt marks prior unfinished spans interrupted.
The ledger and processing events do not store full prompts, transcripts, provider
response bodies, or credentials.

The operator report is available without starting background workers:

```sh
MIX_ENV=prod mix stampbot.operations --hours 24
```

It reports queue age, stage outcomes, failed/unfinished work, known request cost,
unknown-cost requests, current work reservations, and publishing outcomes needing
reconciliation. This is a first operational report and telemetry export point;
no external monitoring service or hosted dashboard was configured.

## Evaluation workflow

The expanded deterministic baseline exercises the actual processor with fixture
IO. It distinguishes source acquisition, pipeline completion, output structure,
and human chapter quality. UNWATCHED/refused/truncated output, malicious input
markers, late-chunk failures, oversized inputs, and absent usage have explicit
contracts. A passing fixture is not a semantic model-quality score.

The new read-only cohort exporter selects actual failed/degraded submissions into
a private manifest and review sheet, with stable video-level tuning/held-out
splits and reported coverage gaps. It starts only Repo, never Oban or providers.
Use the [evaluation instructions](../evals/README.md) and
[human review rubric](../evals/HUMAN_REVIEW.md). A read-only export from the local development database produced two historical
primary-only submissions from August 2025, with unknown duration and language;
one is assigned to tuning and one to held-out review. The private files are under
`tmp/evals/local-development-cohort-2026-09-09/` and are intentionally not committed.
This is a workflow seed, not a representative production cohort. No production
cohort export, paid evaluation, or human quality assessment was performed.

## Rollout and remaining work

Run all included database migrations before the new application version starts;
the Docker entrypoint already runs release migrations. Configure the operator
credential, publication preference, processing allowances, and verified proxy
allowlist for the deployment. No deployment or live posting was performed here.

This milestone does not isolate the caption downloader's runtime or change the
existing production database TLS verification configuration. Those remain the
next infrastructure security work. Per-chunk execution checkpoints, external
telemetry delivery, retention policy, production service targets, and measured
model comparisons also remain future work; the ledger and evaluation workflow
provide the evidence needed to choose them.

## Verification on September 9, 2026

- 149 Elixir tests passed, including independent PostgreSQL budget/publication
  races, interrupted request recovery, atomic cost/ready persistence, and direct
  authorization bypass attempts.
- 11 JavaScript tests and the mocked Chromium acceptance/reopen checks passed.
- The offline baseline passed 21 pipeline cases and 13 URL contracts, matching
  all 49 simulated HTTP requests to durable ledger rows.
- Compilation with warnings treated as errors, formatting for all changed
  Elixir/HEEx files, and `git diff --check` passed.
- The operator CLI returned valid standalone JSON. The cohort exporter performed
  a bounded read-only query against the local development database and created
  private artifacts without starting workers.

The repository-wide formatter still has the unrelated formatting differences
recorded in milestone one. Model calls and YouTube posting remained mocked.
