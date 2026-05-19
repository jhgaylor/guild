# 0009 — Decisions log retention policy: retain indefinitely (Wedge B)

**Status:** Accepted

## Context

`decisions_log` rows include a `context_snapshot` field — a full copy of the context packet delivered to the worker at decision time. These rows will be the largest in the database by average row size. A retention policy must be chosen before the table is created so the migration does not need to be revisited for operational reasons mid-wedge.

## Decision

**Retain indefinitely for Wedge B.** No archival, no rolling delete, no hash-only strategy. Wedge B processes a single seeded thread; total `decisions_log` volume is negligible and the full audit trail is worth more than any storage savings.

A migration-level comment is placed in the `decisions_log` migration file:

```sql
-- TODO(retention): revisit at G3 when fleet scale changes the calculus
```

This is a forcing function: it appears in the file that creates the table, so any engineer touching the migration before G3 will see it.

## Consequences

- Simplest possible policy; no operational complexity introduced.
- Full audit trail preserved: every `context_snapshot` is available for debugging, evaluation, and retrospective analysis.
- `context_snapshot` will grow unboundedly in production fleet use. This is the known deferred risk; the TODO is the explicit commitment to address it before G3.
- No infrastructure dependency on cold storage (S3 or equivalent) is introduced at this milestone.

## Alternatives considered

- **Rolling delete after T days** — rejected: T is unknown without production data. Choosing a number now would be arbitrary and potentially destructive to the audit trail.
- **Archive to cold storage after N days** — rejected: adds an infrastructure dependency (S3 or equivalent) before we know whether we need it. Premature for Wedge B's volume.
- **Store hash only after N days** — rejected: loses auditability of the actual context delivered to the worker, which defeats the primary purpose of the decisions log. Forensic value is in the content, not the hash.
