# 0006 — Thread linkage resolution: explicit references only (Wedge B)

**Status:** Accepted

## Context

When an event arrives, Guild must assign it a `thread_id`. Some events carry explicit references to a work item — a PR with "Fixes #42" in the body, a Fountain conversation whose metadata names a specific thread. Others carry no reference at all. The question is: how does Guild decide which thread an ambiguous event belongs to?

## Decision

For Wedge B: **explicit references only**. An event is linked to a thread if and only if it carries an explicit reference — a GitHub PR linked to an issue, a commit message containing "Fixes #N", a Fountain conversation tied to a specific thread via its metadata. Events with no explicit reference are ingested with `thread_id = null` and remain unlinked.

Unlinked events are not discarded; they persist in the `events` table and can be retroactively linked if the linking strategy is upgraded in a later milestone.

## Consequences

- No silent mislinks: every linked event has a traceable, auditable reason for its assignment.
- Trivially correct for Wedge B's scope (a single seeded thread); explicit references cover all expected events in that scenario.
- Some events that a human would associate with a thread will land unlinked. This is acceptable for Wedge B and must be revisited at G3 when multi-thread volume makes explicit-only limiting.
- The `events.thread_id` nullable column is load-bearing: it represents "not yet linked," not an error state.

## Alternatives considered

- **Heuristic linking** (time window + repository + actor matching) — rejected for Wedge B: Wedge B has exactly one seeded thread, so heuristics add implementation complexity for zero practical benefit. Silent mislinks corrupt the thread model; the correctness risk is not acceptable when the scope is one thread.
- **LLM-based linking** — rejected for Wedge B: same scope reasoning; also introduces a non-deterministic step in a plumbing component. Revisit at G3+ when multi-thread volume makes explicit-only demonstrably insufficient.
