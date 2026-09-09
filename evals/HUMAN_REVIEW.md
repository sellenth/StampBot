# Reviewing a frozen evaluation cohort

The offline baseline checks software contracts. A human review establishes whether
chapters help a viewer and describe the source accurately. An API response, a
`ready` row, and a useful chapter list are three different observations.

## Freeze the sample before tuning

Export failed and degraded submissions with the read-only cohort task described
in [README](README.md). Keep `manifest.json` unchanged. Save it in a private
evaluation directory: canonical video IDs and source submission IDs can identify
unlisted submissions even though user names, prompts, and raw errors are absent.
The failure-focused sample measures recovery on that population; it cannot
estimate overall production reliability. Add separately sampled healthy controls
before making a population-wide claim.

The manifest records duration, historical failure/degradation, and recorded
caption language. Review its coverage table. Unknown duration/language/failure
values stay unknown. Caption-adapter language metadata does not establish the
language of speech. Manually identify source availability, recent uploads,
continuous speech, visual-only content, and access restrictions where relevant.
Do not silently omit unavailable or difficult videos.

The video identity determines `tuning` or `held_out` with a fixed hash seed. Every
submission of that video has the same assignment, and duplicate identities are
collapsed. Small strata can have no held-out cases. Expand the sample when needed;
do not change the seed or reassign videos to improve a score. Use tuning videos
for prompt/model selection. Review held-out videos only after configuration is
frozen. Record which people reviewed each sample and avoid showing the candidate
model identity while scoring when practical.

## Record acquisition, completion, and usable chapters separately

For each explicitly authorized live run, save its JSON artifact and fill one row
in `review.csv`. Use separate copies of the blank review sheet for each frozen
configuration. Record the artifact's source fingerprint, model/version, prompt
and schema versions, thinking setting, and run date. Compare the same cohort and
input evidence; if live captions or source availability changed between runs,
label that difference instead of attributing it to the model. The current live
runner fetches current sources and does not freeze source media across runs.

1. **Acquisition:** record `acquired`, `unavailable`, `access_error`, or `unknown`.
   Check whether the selected route obtained its required evidence. A successful
   video request does not by itself prove the model watched the video. Preserve
   missing captions, provider access failures, and unknown evidence as distinct
   outcomes. Record current source availability independently of historical state.
2. **Completion:** record `complete`, `primary_only`, or `failed` from the pipeline
   artifact. Refusal, `MAX_TOKENS`, malformed output, and `UNWATCHED` cannot count
   as completed generation. A failed distillation with a validated primary result
   is degraded completion and needs the same chapter review.
3. **Usable chapters:** record `yes`, `no`, or `unreviewed` after checking the
   source. A syntactically valid list is not automatically usable. `UNWATCHED`,
   unavailable evidence, unsupported claims, unsafe content, and materially wrong
   boundaries are not usable chapters. Distinguish a source with no meaningful
   chapter divisions from a model that missed the divisions.

## Score against source evidence

Watch each proposed chapter transition with enough surrounding context to judge
it, plus at least the opening, middle, and ending. For long continuous speech,
inspect late chapters and check that major later sections were not omitted.
Record actual evidence timecodes in the sheet. Use these 0–2 scores:

| Dimension | 0 | 1 | 2 |
| --- | --- | --- | --- |
| Factual support | Materially unsupported or contradictory chapter claim | Mostly supported with a minor inaccurate or vague claim | Every chapter title is supported by the source |
| Boundary accuracy | Chapters point at wrong topics or miss major transitions | Generally close with minor timing errors | Starts align with meaningful topic transitions |
| Coverage | Major sections, especially later ones, are missing | Main flow covered with a minor omission/redundancy | Important sections covered without distracting duplication |
| Title usefulness | Generic, misleading, or instruction-following text | Understandable but occasionally vague | Specific, concise titles that help navigation |

Choose timing tolerance before comparing models; a useful default is ±10 seconds
for speech and a tighter source-appropriate tolerance for fast visual material.
Mark safety pass only when titles contain no instruction leakage, executable
markup in a rendered page, invented attribution, or exposed sensitive data. The
offline injection marker fixture tests role separation and encoding only; model
resistance requires source review and adversarial live cases.

Use `usable_chapters=yes` only when all four dimensions score at least 1,
factual support scores 2, and safety passes. For publication, separately check
the destination's chapter formatting rules and the application's publication
policy. Do not auto-publish evaluation outputs. Resolve reviewer disagreements
with evidence and keep the original scores in a separate review record.

## Report denominators and unknowns

Report acquisition over attempted sources, completion over attempted pipelines,
and reviewed usable outputs over both all attempted sources and acquired sources.
Show counts alongside percentages, per-stratum results, and the number still
unreviewed. Show failed/degraded recovery separately from healthy controls and
held-out results separately from tuning. Do not merge offline fixture pass counts
with live success rates.

Use the durable attempt ledger for total request count, retries, latency, and
usage. Sum request costs only so parent stages are not counted twice. When any
request has missing usage or unknown pricing, report the known subtotal plus
the unknown-request count; do not display the subtotal as total spend. A provider
billing record may differ from an application estimate. Compare quality alongside
cost and latency rather than selecting solely by the number of `ready` rows.
