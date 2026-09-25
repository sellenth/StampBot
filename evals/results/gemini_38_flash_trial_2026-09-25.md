# Gemini 3.8 Flash production-pipeline smoke trial

On September 25, 2026, the operator authorized a small live trial of Gemini 3.8
Flash. The existing historical cohort supplied two short video-route controls.
Each source ran once with 3.7 Flash and once with 3.8 Flash using the actual
`Submissions.Processor` pipeline, including metadata refresh, validation,
distillation, request recording, and budget reconciliation.

Both configurations used medium video thinking, low media resolution, and
Gemini 3.5 Flash-Lite with low thinking for distillation. Each run was limited
to four provider requests and a $3 local reservation budget. All runs executed
against the isolated local test database with row writes rolled back and
publication disabled. These trial costs therefore are not in the production
budget ledger. No prompts or production data were changed for the comparison.

| Source | Video model | Pipeline result | Requests | Elapsed | Estimated cost |
| --- | --- | --- | ---: | ---: | ---: |
| [Kingdom Hearts gameplay trailer](https://www.youtube.com/watch?v=5qm6_DoM1Pc), 224 s | 3.7 Flash | Complete | 2 | 11.296 s | $0.017768000 |
| Same source | 3.8 Flash | Complete | 2 | 10.269 s | $0.017542850 |
| [Waterfall animation](https://www.youtube.com/watch?v=7aYqQN2IzS8), 421 s | 3.7 Flash | Complete | 2 | 11.634 s | $0.032275400 |
| Same source | 3.8 Flash | Complete | 2 | 11.027 s | $0.033126950 |

All eight provider requests succeeded on their first attempt and reported usage.
Every run completed both video generation and Flash-Lite distillation, with
timestamps accepted by production validation. Returned video model identifiers
matched the requested 3.7 or 3.8 model. The total estimated cost was **$0.100713200**:
$0.050043400 for the 3.7 arm and $0.050669800 for the 3.8 arm. Costs include both
pipeline stages and use configured token rates; provider billing can differ.

This is a compatibility smoke test, not evidence of better chapter quality or
overall reliability. Chapter factual support and boundaries remain unreviewed
against source footage. The live sources were not frozen between runs. Two
visual clips do not cover long speech, captions, restricted sources, or all
failure cases, and one observation per model/source is insufficient to compare
latency or cost distributions.

The trial supports enabling `gemini-3.8-flash` for video with existing settings.
Caption summarization and distillation remain on `gemini-3.5-flash-lite`. Both
3.7 and 3.8 rates remain configured so rollback to 3.7 retains cost accounting.

Artifacts with generated chapters, source fingerprints, request outcomes,
usage, and timing are in the ignored local directory
`tmp/evals/gemini-38-trial/{37,38}-{gameplay,animation}.json`.

The offline baseline before the trial passed 23/23 pipeline cases and 13/13 URL
checks. This checks software contracts with fixtures, not real-video quality.
After changing the default to 3.8, all 198 Elixir tests passed and the offline
baseline again passed all 23 pipeline cases and 13 URL checks.

Google references: [3.8 model capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)
and [pricing](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.8-flash).
Standard introductory pricing is $0.75 input, $0.075 cached input, and $3.75
output (including thinking) per million tokens through December 31, 2026;
these rates must be reviewed before the scheduled January 2027 increase.
