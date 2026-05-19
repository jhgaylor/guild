# 0007 — Context assembly: bounded recency window (Wedge B)

**Status:** Accepted

## Context

Before each worker decision, Guild assembles a context packet from the thread's history. A thread may accumulate hundreds of events over its lifetime. The context packet must fit in the worker's context window and must not be stale. The question is: how should `Guild.ContextAssembly.build/1` query the thread's event history?

## Decision

**Bounded recency window.** `Guild.ContextAssembly.build/1` fetches:

1. The last **N** events on the thread, ordered by timestamp descending, where N is a compile-time constant (initially `50`).
2. **All** `context_notes` of type `human_instruction`, unconditionally — regardless of age.

No summarization. No pre-computed rows. No rolling window logic. This is the simplest version that works for Wedge B's scope.

A `# TODO(summarization): revisit when thread length forces it — i.e., when the bounded window demonstrably loses important context in production` comment is placed in the assembly module to flag the known limitation and prevent it from being forgotten.

## Consequences

- Simple to implement and test: one bounded query, one unconditional fetch, one assembly step.
- No write-path side effects: nothing is updated when a context packet is built.
- Does **not** add a `summary` column to `threads` — this ADR explicitly defers that column until summarization is designed.
- Will not scale to long-running threads with large event histories. Acceptable for Wedge B (single short-lived thread). The TODO is a forcing function to address this before G3.

## Alternatives considered

- **Cursor-based pagination with rolling summarization** — rejected for Wedge B: significant implementation complexity; Wedge B's single short-lived thread will never overflow the window, so the complexity has no payoff.
- **Pre-computed summary rows** (a `summary` column on `threads`, updated on each event insert) — rejected: requires write-path complexity and a migration that adds a column before the shape of a useful summary is understood. Premature optimization; adds accidental coupling between ingestion and context assembly.
