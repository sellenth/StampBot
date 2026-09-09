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

Verify ingress addresses and configure the new trusted-proxy allowlist before
rollout; the default transport-peer fallback can group multiple users behind a
shared proxy. Review the proposed processing allowances and publication default
against the deployment's budget and intended product behavior.

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
Add per-caption-chunk execution checkpoints so a late failure does not repeat
successful excerpts. The current checkpoint remains between generation and
final distillation; the ledger preserves evidence of earlier work but does not
reuse every successful chunk.
