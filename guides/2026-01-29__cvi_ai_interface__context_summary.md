<!--
COPILOT INSTRUCTIONS (READ CAREFULLY):

You are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.

DO:
- Describe intent, pressure, goals, blind spots
- Use plain language
- Leave unknowns explicit

DO NOT:
- Propose solutions
- Invent metrics
- Write code
- Make decisions
- Use theory language

This file is a SITUATIONAL SNAPSHOT, not a design doc.

Component: CVI / AI Interface (Callosum Vector Integration)
-->

# Contextual Summary — CVI / AI Interface

## Component Role

Mediate communication between AI components and databases. Provide request/response carousel for structured, audited conversations. Gateway (cvi_gateway.php) exposes whitelisted stored procedures over HTTP. Workers (PowerShell) post queries; processors execute; responses returned to workers.

## Current Intent

Enable AI to read system state and propose actions without direct write access. Keep all AI communication parameterized and logged. Separate AI authentication from database access (token vs. credentials). Build audit trail of AI reasoning.

## Operating Mode

AI posts structured request JSON via gateway. Gateway validates token, looks up procedure whitelist, executes stored procedure. Results returned as JSON. AI reads response, optionally posts follow-up. All requests logged in cvi_carousel table.

## Frequency & Cadence

Opportunistic (on-demand). AI queries when analyzing system state. Processor executes immediately or queues for batch. Response available within seconds to minutes (not real-time). Spools written continuously; aggregated into lake_vector periodically.

## Pressures Detected

CVI not yet deployed (only schema + PHP skeleton exist). AI components not registered (no cm_components entries). Request/response carousel not populated (no traffic). Gateway token hardcoded (should be environment variable). Whitelisted procedures not defined (gateway has empty allowed_procs).

## Active Constraints

HTTP-only (no WebSocket, no streaming). Token-based auth (shared secret, no per-AI identity). Blocking (AI waits for response; no async pattern). Limited to whitelisted procs (extensible but manual). Response size limited (HTTP payload limits).

## Short-Horizon Goals (Now → Soon)

Deploy gateway to production. Register AI components (me, NeuroNet, future ML models). Define initial whitelist of safe procedures. Test request/response flow end-to-end.

## Long-Horizon Goals

Per-AI authentication (not shared token). Async request/response (queues, subscriptions). Streaming responses (for large datasets). Rate limiting and quota tracking per AI. Signed requests (HMAC verification).

## Blind Spots

Unknown which stored procedures should be whitelisted (safety vs. utility tradeoff). No clarity on AI → AI communication (can AIs talk to each other via CVI?). Unknown how many concurrent requests CVI can handle. No error handling strategy (what if SP timeout?).

## Friction Points

Token in code (should be in .env). Gateway validation weak (no signature check, no rate limit). Whitelist requires manual updates (no dynamic registration). No circuit breaker (failed SP doesn't gracefully degrade). Request/response schema not validated.

## Metrics Currently Used

None yet (not deployed).

## Metrics Missing

Request volume per AI component. Request latency (AI → gateway → SP → response). Error rate (failed requests, timeouts). Token usage (unusual patterns?). Whitelist hit rate (which procedures used most?).

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_cvi_register_component()` - register new AI entity with token
- `sp_cvi_get_whitelist()` - return allowed procedures for requesting component
- `sp_cvi_log_request()` - audit log for CVI traffic
- `sp_cvi_get_component_quota()` - check request quota for AI

## Desired Context From Other Components

All: Can I trust CVI to be the comms channel? Governance: Should AI requests be checked against rules? Ops: How do we monitor CVI health? Database: Which SPs are safe to expose to AI?

## Confidence Level

High on architecture (CVI design is solid, schema exists). Low on deployment (not in production yet). Low on adoption (no AI components using it). Low on safety (whitelisting not finalized).

## Notes

CVI is the intended channel for AI ↔ system communication but is still a blueprint. It requires activation (deployment + registration) before it becomes a living part of the system. Current state: ready to deploy, waiting for go-ahead.
