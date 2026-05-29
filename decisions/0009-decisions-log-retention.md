# 0009 — Decisions log retention policy: rolling null beyond 200 (G4 update)

**Status:** Accepted (Updated G4)

## Context

`decisions_log` rows include a `context_snapshot` field — a full copy of the context
packet delivered to the worker at decision time. At G4 fleet scale, unbounded growth
of this field becomes an operational concern. The TODO comment added in G0 is now
addressed.

## Decision

**Keep full rows for the most recent 200 decisions per thread; null `context_snapshot`
on older rows while preserving `decision_type`, `params`, `reasoning`, and timestamps.**

`Guild.Retention.trim_decisions_log/1` is called automatically when a thread reaches
`:done` state in `Guild.Reconcile`. The function:

1. Queries `decisions_log` for the given thread, ordered by `id` descending.
2. Takes the first 200 IDs (the most recent rows).
3. Updates all remaining rows for that thread, setting `context_snapshot = nil`.

The full audit trail (action, params, timestamps) is preserved; only the large blob
field is cleared on older rows.

## Consequences

- Storage growth is bounded per thread (200 full rows + unlimited lightweight rows).
- Audit trail remains: action type, params, and timestamps are always available.
- The most recent 200 snapshots are kept for active debugging and evaluation.
- Implemented as a cleanup step at thread completion, so write-path latency is unaffected.

## Alternatives considered

- **Rolling delete after T days** — rejected: destroys the audit trail for old threads.
- **Archive to cold storage** — rejected: infrastructure dependency not justified at current scale.
- **Store hash only** — rejected: loses forensic value; content not recoverable.
- **Trim on every reconcile cycle** — rejected: unnecessary overhead; trimming at completion is sufficient.
