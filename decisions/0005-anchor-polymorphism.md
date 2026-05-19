# 0005 — Anchor polymorphism via discriminator pair

**Status:** Accepted

## Context

Threads must anchor to external work items — GitHub issues, Linear issues, and other source types to be added later. The anchor must be stored in Postgres in a way that supports foreign-key-style lookups by thread, is queryable by source type, and doesn't require a schema migration when a new source type is introduced.

## Decision

Use a discriminator pair on the `threads` table: two columns, `anchor_type` (varchar, e.g. `"github_issue"`) and `anchor_id` (varchar — the source-native ID, e.g. `"123"` for GitHub issue #123). A composite unique index on `(anchor_type, anchor_id)` enforces one thread per work item across all source types.

`anchor_type` values are documented as an implicit enum in the schema module (`Guild.Schema.Thread`), not in a DB constraint, so adding a new source type requires only a new string value and a schema-module annotation — no migration.

## Consequences

- Simple schema: two plain varchar columns, one composite unique index, no join tables.
- Easy extensibility: adding a new source type (e.g. `"jira_issue"`) is a new string value; zero migration required.
- Indexed lookups on `(anchor_type, anchor_id)` are cheap and cover the primary access pattern.
- No DB-level foreign key to the source system — intentional, since external IDs are not rows we own. The application layer must validate `anchor_type` values against the documented set.
- The implicit enum is a maintenance artifact: new source types must be added to the schema module documentation, not just used in data.

## Alternatives considered

- **Separate tables per anchor source** (e.g. `github_issue_threads`, `linear_issue_threads`) — rejected: premature schema explosion for two sources; joining across source types becomes progressively more complicated as sources multiply.
- **JSONB blob** (`anchor jsonb`) — rejected: throws away type safety and makes indexed lookups on anchor type awkward; there is no compile-time contract on shape, and partial-index queries on JSONB keys are more painful to write and explain.
