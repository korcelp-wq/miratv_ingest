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

Component: Governance / IGM (Inhibitor Governor Matrix + i_m_g_vector_context)
-->

# Contextual Summary — Governance / IGM

## Component Role

Enforce architectural rules (canon). Hold candidate rules pending human review. Track governance decisions and attestations. Two databases in twin formation (inhibitor_govenor_matrix, i_m_g_vector_context). Canon rules are enforceable; provisional rules inform but don't block.

## Current Intent

Embed governance into system execution, not as external checklist. Make rules observable and auditable. Distinguish between canon (hard constraints) and provisional (guidance). Enable humans to promote rules to canon as confidence grows.

## Operating Mode

Stored procedures read rules before allowing operations. Attestation spools record rule evaluation in real time. Candidate rules staged for human review. Canon rules enforced at ingest/write time. Overrides logged and escalated.

## Frequency & Cadence

Rule evaluation on every write (real-time). Human review of candidate rules (ad-hoc, weekly?). Rule promotion to canon (formal, rare). Attestation spools written continuously; aggregated periodically.

## Pressures Detected

Candidate rules accumulating without formal review process. Human reviewers unclear (who can promote to canon?). No feedback loop from enforcement (blocked operations not visible to rule authors). Provisional rules remain provisional indefinitely. Rule conflicts undetected (two rules contradict but both active).

## Active Constraints

No rule versioning (old rules can't be deprecated easily). Twin constraint (inhibitor_govenor_matrix ↔ i_m_g_vector_context must stay synchronized). No rule composition (can't say "rule A applies IF rule B is active"). Attestations are append-only (can't revise historical judgments).

## Short-Horizon Goals (Now → Soon)

Promote TOGAF 6 principles to canon. Establish rule review board and promotion criteria. Route all component writes through governance checks. Make attestation spools queryable.

## Long-Horizon Goals

Automatic rule inference (ML suggests new rules based on pattern violations). Rule evolution (deprecate, versioned rules). Cross-rule dependency tracking. Human-AI collaboration on rule confidence (AI proposes, humans decide).

## Blind Spots

Unknown which operations should trigger rule checks. Unclear if existing operations violate rules (audit trail doesn't exist yet). No way to test rule changes before deployment. Unknown rule impact (what operations would be blocked by this rule if activated?).

## Friction Points

Rule review process not formalized. No tool to simulate rule activation. Attestation spools verbose; hard to extract signal. Twin-write enforcement relies on application layer (not DB-enforced). Candidate rules don't show which operations they'd affect.

## Metrics Currently Used

Rule count (canon vs. provisional). Attestation count (per rule, per status).

## Metrics Missing

Rule violation frequency (how often are blocked operations attempted?). Rule promotion latency (time from candidate to canon). Override frequency (how often are rules bypassed?). Attestation completion rate (% of operations with attestation vs. silently succeeding).

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_evaluate_rule_set()` - check if operation violates any canon rules
- `sp_simulate_rule_activation()` - show what operations would be blocked if rule activated
- `sp_promote_rule_to_canon()` - promote candidate rule (requires human approval)
- `sp_find_rule_conflicts()` - detect contradictory active rules

## Desired Context From Other Components

All: Which of my writes need rule checks? Database: Have rule checks detected constraint violations before? Grinder: Are there rules about acceptable provider data? Ops: Should failed jobs trigger governance escalation?

## Confidence Level

High on current state (candidate rules visible in DB, canonical principles known). Medium on application (which operations are actually checking rules?). Low on impact (what happens if we enforce all candidate rules?).

## Notes

Governance is currently advisory (candidate rules) to enforcement-ready (canon rules). This transition is the critical unknown: which rules should be canon, and who decides? Human authority is essential but not yet formalized.
