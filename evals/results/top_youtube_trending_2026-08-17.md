# Top YouTube trending model eval — 2026-08-17

Source snapshot: [TrendTube](https://trendtube.adaptivemind.tech/), captured at
2026-08-17 19:00 PDT. YouTube metadata was queried after the run to verify each
video duration.

The sample uses ranks 1, 2, 5, 8, and 10 from the current U.S. top ten. The same
structured prompt and response schema were used for both configurations.

| Rank | Duration | Legacy result | Modern result | Modern score | Modern latency |
| ---: | ---: | --- | --- | ---: | ---: |
| 1 | 2:29 | Pass after one repair retry | Pass, first attempt | 88 | 3.8 s |
| 2 | 2:10 | Failed duration validation twice | Pass, first attempt | 90 | 13.6 s |
| 5 | 27:15 | Failed transport twice | Pass after one transport retry | 100 | 98.6 s |
| 8 | 3:44 | Failed duration validation twice | Pass, first attempt | 90 | 17.8 s |
| 10 | 7:01 | Failed duration validation twice | Pass, first attempt | 90 | 16.0 s |

## Summary

| Configuration | Success | Mean heuristic score | Mean elapsed time | Observable successful-call cost |
| --- | ---: | ---: | ---: | ---: |
| `gemini-2.5-flash` + `gemini-3-flash-preview` | 1/5 (20%) | 100 for the sole success | 49.0 s across all outcomes | $0.0131 |
| `gemini-3.7-flash` + `gemini-3.5-flash-lite` | 5/5 (100%) | 91.6 | 29.9 s | $0.0924 |

The score is a deterministic smoke-test heuristic covering chapter-count target,
timeline coverage, start position, title length, and the absence of `UNWATCHED`.
It is not a human semantic-quality judgment. The modern outputs missed the
preferred chapter count on four short videos but passed all hard schema, ordering,
and duration checks.

Costs are estimates from usage metadata returned by successful calls at the
published regular, cached-input, and output-token prices. Failed or superseded
retry attempts do not expose usage through the current eval harness, so both
totals are lower bounds and the legacy total is not suitable for direct cost
comparison.
