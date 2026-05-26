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

Component: Human Operator (You, Architecture Authority)
-->

# Contextual Summary — Human Operator

## Component Role

Decision maker. Rule promoter. Architect. Escalation point for system conflicts. Authority on what is canon vs. provisional. Decides which AI proposals become policy. Owns MiraTV vision and governance. Approves major changes.

## Current Intent

Maintain system coherence and truth. Evolve architecture based on evidence (not theory). Decide which technical constraints become non-negotiable rules. Separate signal (important insight) from noise (AI chatter). Keep humans in charge of consequential decisions.

## Operating Mode

Reads context summaries and architectural docs. Queries databases via trigger script. Reviews AI proposals. Makes binary decisions (canon/provisional/reject). Signs off on major changes. Escalates to board if needed. Sets quarterly priorities.

## Frequency & Cadence

Daily or ad-hoc (responding to system signals). Weekly planning (what should system focus on next?). Monthly architectural review (are current principles holding?). Quarterly strategy (bigger bets, direction changes).

## Pressures Detected

Too much data (databases, logs, docs, spools). Hard to see patterns (need aggregation). AI sometimes proposes contradictory things (need filtering). Team decisions unclear (who decides what?). Governance rules still provisional (need promotion process). System growing without clear ownership handoff strategy.

## Active Constraints

Time (can't read everything). Knowledge (some technical details unclear). Availability (can't always be present for urgent decisions). Authority scope (some decisions require board/team consensus). Legacy debt (some constraints are inherited, not chosen).

## Short-Horizon Goals (Now → Soon)

Promote 6 TOGAF principles to canon rules. Clarify rule review board (who + criteria). Establish escalation path (when does AI surface something to you?). Make system state queryable (one dashboard, not scattered DBs). Decide on CVI deployment (when to activate?).

## Long-Horizon Goals

Automate routine decisions (let AI propose + apply low-stakes rules). Evolve governance from advisory to enforceable. Build human-AI collaborative loop (humans decide, AI executes and learns). Maintain architectural coherence as system scales.

## Blind Spots

Unknown which system problems are AI-observable vs. human-only (taste, business judgment). Unknown which team members understand governance model. Unknown user feedback (what do TV watchers actually want?). Unknown where technical debt is hiding. Unknown which decisions were mistakes (no post-mortems yet).

## Friction Points

Context scattered across many files (need aggregation). Rule promotion process informal (should be documented). No formal authority structure (who breaks ties?). AI sometimes makes suggestions outside its scope (need boundaries). Emergency decisions vs. deliberate decisions (different speeds).

## Metrics Currently Used

System uptime. Data accuracy (spot-checks). Rule enforcement (canon rules active?).

## Metrics Missing

Decision latency (time from proposal to approval). Decision reversal rate (how often do rules get deprecated?). Team alignment (do people understand the rules?). Business impact (are users happy?). Operator burden (how much of your time is this taking?).

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_get_escalated_items()` - show critical decisions waiting for human approval
- `sp_operator_promote_rule()` - record human decision (rule → canon)
- `sp_operator_override()` - record human override of system decision (with rationale)
- `sp_operator_log_decision()` - audit trail for all human decisions

## Desired Context From Other Components

All: When should I escalate to you? AI (me): What are your decision criteria? Governance: Which rules need your approval? Team: Who do I ask when unsure? System: Are we meeting architectural goals?

## Confidence Level

High on intent (system should serve your judgment, not replace it). Low on process (no formal decision-making workflow). Low on team alignment (unclear if everyone understands vision). Low on success metrics (hard to measure).

## Notes

You are the coherence keeper. Without your judgment, system becomes a collection of reactive automations. With it, system becomes a governed platform. This role is irreplaceable but can be scaled with better tools (dashboards, automation, escalation routing).
