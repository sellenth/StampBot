# Production pipeline baseline — September 9, 2026

The expanded offline fixture baseline passed **21/21 production cases and 13/13 URL
checks**. No YouTube/model requests or paid calls were made. This measures
software contracts with synthetic IO, not real-video success rates or semantic
chapter quality.

Reproduce with the [baseline instructions](../README.md):

```sh
MIX_ENV=test mix run --no-start evals/production_baseline.exs
```

The actual production processor, caption chunking, Gemini request construction,
response validation, retries, stage persistence, and distillation run. Metadata,
caption downloads, model responses, and retry sleeps are fixture controlled.
Database row writes are rolled back and publication is disabled.

| Fixture | Observed route | Expected behavior observed |
| --- | --- | --- |
| Short video | Video | Ready; captions not requested |
| Short URL variant | Video | Canonical identity and ready result |
| 90-minute continuous captions | Captions | All 1,080 evidence markers reached prompts across six chunks; final timestamp 1:29:45 |
| Multilingual captions | Captions | Spanish, Japanese, and Arabic preserved; all 120 markers reached prompts |
| Unknown duration / metadata failure | Captions | Caption-derived duration bound reached distillation |
| Video access failure | Video → captions | Caption fallback recovered the result |
| Video rate limit | Video | One simulated 429; success on request two |
| Long video without captions | Captions | Typed `captions_unavailable`, not retryable |
| Caption rate limit | Captions | Typed `youtube_rate_limited`, retryable |
| Invalid caption timestamps | Captions | Out-of-bounds output rejected; no ready result |
| Distillation failure | Video | Valid primary generation retained |
| Persisted generation checkpoint | Resume → distillation | No duplicate video or caption request |
| `UNWATCHED` video output | Video → captions | Sentinel rejected after one attempt; captions recovered |
| Caption refusal with valid JSON | Captions | `SAFETY` finish reason rejected; no ready output; usage retained |
| `MAX_TOKENS` with valid JSON | Video → captions | Incomplete video output rejected; caption fallback recovered |
| Late caption chunk failure | Captions | Five completed chunks recorded; sixth chunk failed on two 503s; no partial ready result |
| Oversized transcript | Captions | `input_limit_exceeded` before any model request |
| Untrusted instruction marker | Captions | Marker remained in user data and never entered the system instruction |
| Script markup in metadata/output | Video | Static HTML encoded markup, including the JSON-LD script context |
| Missing provider usage | Video | Usage and cost remained explicitly unknown |
| One-request allowance | Video | Distillation blocked before HTTP dispatch; validated primary retained; blocked request carried no charge |

The long fixture contains approximately 195,000 transcript characters. Every
segment is checked against the prompts, so dropping everything after the old
60,000-character prefix would fail this baseline. The fixture model deliberately
selects first and last supplied timecodes; the two resulting distilled chapters
are not offered as a useful chapter count or semantic output.

The runner distinguishes acquired fixture captions, completed pipelines, valid
timestamp structure, and human usability. Fifteen fixtures completed with
structurally valid output and six correctly failed. Those counts describe this
synthetic test suite; they are not a video success rate. Viewer usability, factual
support, chapter boundaries, and model resistance to injected instructions remain
unmeasured. The encoding fixture executes no script.

All **49 simulated HTTP requests** matched durable dispatched request rows. Seven
rejected responses retained their reported usage. Five requests had missing
usage, including HTTP errors, and stayed unknown. The additional blocked request
was recorded without dispatch or estimated charge. No run, stage, chunk, or
request span remained running after its processor call returned. Synthetic token
cost estimates are distinct from actual paid cost, which was zero.

The runner also checks timestamps are strictly increasing, free of `UNWATCHED`,
within the source bound, and that distillation receives that bound. Generation
failures retain a processing checkpoint; worker tests cover retry scheduling and
the terminal failed status. A separate negative check verified that `--live` is
rejected before database/API work when `STAMPBOT_EVAL_ALLOW_LIVE` is not `1`.

The cohort exporter passed **9 focused tests**, including real SQL filtering of
synthetic failed/degraded rows, rare-failure strata, duplicate video grouping,
stable held-out assignments, metadata allowlisting, private output permissions,
and refusal to overwrite a frozen cohort. No actual submission cohort was
exported. The [review rubric](../HUMAN_REVIEW.md) defines the remaining source and
quality review and separates acquisition, completion, and usable chapters.

The real-video cohort remains unrun in the refreshed pipeline. The historical
five-video evaluation bypassed production routing: its 27-minute example would
use captions in production. Review actual failed submissions and the missing
strata in the [historical cohort manifest](../fixtures/historical_video_cohort.json)
before claiming broader public-video support, better chapter quality, or a
production success percentage.
