# Next review after security and measurement

[Milestone two](milestone-two.md) implements the initial publication policy,
account and work limits, JSON-LD fix, persistent attempts, operator report, and
evaluation workflow. The following work remains.

## Infrastructure security

Isolate caption acquisition from the main application environment and system
OAuth credentials. Use a restricted runtime identity, private temporary files,
subprocess/output/file bounds, and tested image updates instead of startup
self-updates. Test that termination also cleans up the child process.

Production database TLS still uses `verify_none`. Configure CA and hostname
verification for the actual deployment and test both valid and invalid server
identities. Do not guess the provider's CA or silently fall back to no verification.

Production uses the explicit Railway proxy mode after verification of its HTTP
ingress and absence of a public TCP bypass. Reverify that boundary if networking
changes. Review processing allowances and publication settings against actual
usage and intended product behavior.

## Real outcome evaluation

Export a frozen failure-focused cohort using the new read-only task, review its
coverage, and add healthy controls before estimating overall success rates. Run
a small measured sample first, then expand toward 100–200 cases if useful.

Report acquisition success, processing completion, and usable chapters separately.
Use the [human rubric](../evals/HUMAN_REVIEW.md) for factual support, coverage,
boundary accuracy, and safety. Keep tuning videos separate from held-out videos;
record current source availability instead of relying on historical metadata.

Compare model and processing-mode changes independently on identical inputs.
Evaluate quality, coverage, latency, and cost per usable result against the
current production pipeline. The offline baseline checks software contracts;
model resistance to malicious instructions and chapter quality remain unmeasured.

## Operations and recovery

Connect the processing events and read-only operator report to the deployment's
monitoring backend. Set service targets from observed queue age, stage latency,
source failures, unknown cost, and publishing uncertainty. Keep identifiers in
traces rather than metric labels, and maintain payload redaction.

Define retention and reconciliation policies for attempt records and uncertain
publication. Export aggregates before pruning detail needed for cost analysis.
Per-caption-chunk checkpoints now preserve validated excerpts across retries and
worker restarts; see [caption recovery](caption-recovery.md). Add operational
retention for these derived chapter records and measure reuse in real workloads.
