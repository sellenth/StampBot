# StampBot ChatGPT plugin experiment

The first version exposes two MCP tools at `https://stamp-bot.com/mcp`:
`generate_chapters(url)` and `get_chapters(job_id)`. It uses the existing durable
submission pipeline, canonical URL deduplication, public results, and processing
budgets. No new inference provider or OpenAI API key is required.

The endpoint implements stateless MCP Streamable HTTP with JSON responses,
initialization, tool discovery, calls, notifications, and ping. It supports
protocol versions `2025-11-25`, `2025-06-18`, and `2025-03-26`. GET and DELETE
return 405 because there is no server-initiated stream or session to terminate.
Browser origins are limited to the configured site origin and `https://chatgpt.com`.

Completed results contain validated, ordered chapter text and YouTube timestamp
links. New requests return a saved job and result-page URL immediately. Clients
should show that link and check again on a later user request, without polling
in a loop. This first experiment does not implement background ChatGPT completion
notifications. Waiting time is a product constraint to measure.

Submitting a video saves its URL and generated chapters publicly. The tool and
listing descriptions disclose this. Plugin-created processing disables automatic
YouTube publication even if website auto-publication is enabled. Reusing an
already active website job does not change that job's publication policy.

## Limits and measurement

New plugin processing is capped at 20 admissions per UTC day, 3 per hashed actor
per UTC day, and 10 per transport bucket per rolling hour. Admission, the usage
record, submission, and work reservation commit in the same transaction. Cached
and active results do not consume another admission. Failed work-budget
reservation rolls back the admission too.

ChatGPT subject and session identifiers are optional, unverified hints. They
are HMAC-hashed with the endpoint secret before persistence, never used for
authentication, and filtered from Phoenix parameter logs. Missing or malformed
subject hints use the existing trusted transport-derived caller bucket. Separate
transport and shared global limits bound subject spoofing. The website's global
USD, request, video, and work limits also apply; a plugin cap is not extra budget.

Runtime overrides:

| Variable | Default |
| --- | --- |
| `STAMPBOT_PLUGIN_ENABLED` | enabled unless `false` |
| `STAMPBOT_PLUGIN_DAILY_NEW_JOBS` | `20` |
| `STAMPBOT_PLUGIN_ACTOR_DAILY_NEW_JOBS` | `3` |
| `STAMPBOT_PLUGIN_TRANSPORT_HOURLY_NEW_JOBS` | `10` |

The usage table stores operations, outcomes, job references, keyed identity
hashes, timestamps, admission flags, and tool response time. It does not store
raw hints, prompts, or video URLs. Existing timestamp records still contain
the public video URL and generated chapters. Keep retention and removal under
operator control while assessing the experiment.

Use the deliberately selected production database to read aggregate usage:

```sh
MIX_ENV=prod mix stampbot.plugin_stats --hours 168 --json
```

This task starts only the Repo. It does not run workers or make provider calls.
It separates generation requests, accepted requests, new jobs, cache reuse,
status checks, and ready deliveries. Returning-subject estimates require
generation requests in more than one session or UTC day; polling is excluded.
Missing subject hints are reported separately. Test calls remain included.
Current result status and cost are aggregated over distinct plugin-admitted
submissions; incomplete accounting and shared retries are called out explicitly.

The report measures tool use. It cannot measure directory impressions,
recommendations, or installations. A zero-call week does not distinguish lack
of visibility from lack of interest. Record launch and testing times, test the
listing's actual discovery in ChatGPT, and use OpenAI dashboard analytics if
available. Assess completed results, return use, and cost before expanding scope.

## Test and package

```sh
MIX_ENV=test mix test test/drag_n_stamp_web/controllers/mcp_controller_test.exs
python3 scripts/package_plugin.py
node scripts/smoke_plugin.mjs --endpoint https://stamp-bot.com/mcp
```

The tests make no provider calls. They cover protocol errors, origin validation,
URL variants, cached chapters, progress, malformed/sentinel results, admission
limits, rollback under budget exhaustion, privacy, demand measurement, and
publication isolation. An independent official MCP SDK client can additionally
verify discovery and responses with a test endpoint and fixture results.

`scripts/package_plugin.py` writes `tmp/stampbot-plugin.zip` from four explicit
files under `plugins/stampbot`: the portable manifest, remote MCP configuration,
and existing StampBot icons. It does not package the repository or credentials.
The manifests declare the official Agent Plugins JSON schemas.

## Publish and connect

1. Deploy the reviewed change using the existing [Railway workflow](deployment.md).
   Release startup applies the new usage-table migration. Confirm `/mcp` discovery
   and `/plugin`, `/plugin/privacy`, and `/plugin/support` in production.
2. In ChatGPT developer mode, add the HTTPS MCP URL with **No authentication**.
   There are no private account capabilities. Test in a new conversation using
   one cached public video, one new request, and its saved job ID.
3. Upload the ZIP at [OpenAI Plugins](https://platform.openai.com/plugins).
   Select the intended verified publisher identity; the dashboard's publisher
   must match the public listing. The package's `StampBot` publisher is draft
   branding until that identity is verified.
4. Complete the domain challenge. Its exact token must be served at
   `https://stamp-bot.com/.well-known/openai-apps-challenge`; this endpoint is
   added only when the dashboard supplies a real challenge token. No placeholder
   challenge is shipped.
5. Replace the review-case URL/job placeholders with actual successful public
   examples, run the five positive and three negative cases in ChatGPT, and
   supply an accessible walkthrough recording URL in the review information.
   The fixture tests do not establish live YouTube availability or chapter quality.
6. Resolve dashboard findings, submit for review, and publish after approval.
   Deploying the endpoint or uploading the ZIP does not make it publicly
   discoverable in the directory.

Support and privacy copy live at `/plugin/support` and `/plugin/privacy`. The
support page links to the public repository issue tracker. Digital-service
upsells are not part of this experiment.

Official references: [MCP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[plugin packaging](https://developers.openai.com/plugins/build/plugins), and
[submission](https://developers.openai.com/plugins/deploy/submission).
