#!/usr/bin/env node
// Read-only smoke check; never calls generate_chapters or a provider.
import assert from "node:assert/strict";
import { parseArgs } from "node:util";

const { values } = parseArgs({ options: {
  endpoint: { type: "string", default: "http://localhost:4000/mcp" },
  "job-id": { type: "string" }
}});
const endpoint = new URL(values.endpoint);
let id = 0;
async function rpc(method, params = {}, notification = false) {
  const body = { jsonrpc: "2.0", method, params };
  if (!notification) body.id = ++id;
  const response = await fetch(endpoint, { method: "POST", headers: {
    "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2025-11-25"
  }, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  if (notification) { assert.equal(response.status, 202); return; }
  assert.equal(response.status, 200, `HTTP ${response.status}`);
  const payload = await response.json();
  assert.equal(payload.jsonrpc, "2.0");
  assert.equal(payload.id, body.id);
  assert.equal(payload.error, undefined, JSON.stringify(payload.error));
  return payload.result;
}

const initialized = await rpc("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "stampbot-read-only-smoke", version: "1.0.0" } });
assert.equal(initialized.serverInfo.name, "stampbot");
await rpc("notifications/initialized", {}, true);
const { tools } = await rpc("tools/list");
assert.deepEqual(tools.map(tool => tool.name), ["generate_chapters", "get_chapters"]);
await rpc("ping");
assert.equal((await fetch(endpoint, { headers: { Accept: "text/event-stream" }, signal: AbortSignal.timeout(15000) })).status, 405);
if (values["job-id"]) {
  const result = await rpc("tools/call", { name: "get_chapters", arguments: { job_id: values["job-id"] } });
  assert.ok(["ready", "processing", "error"].includes(result.structuredContent.status));
  console.log(`Saved job: ${result.structuredContent.status}`);
}
console.log(`StampBot MCP discovery, initialization, notifications, ping, and stateless transport passed at ${endpoint}`);
