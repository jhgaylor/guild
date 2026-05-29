# 0013 — Multi-Repo Deployment

**Status:** Accepted

## Context

Guild was initially designed to monitor a single repository: `jhgaylor/guild` itself. The repository under observation is implicit — baked into environment configuration and assumed throughout the webhook routing and thread-creation paths. This is sufficient for a self-hosting bootstrap but rules out the primary value proposition: running one Guild deployment that manages work across multiple repositories, potentially owned by different organizations.

The blocking question is not technical difficulty but operational clarity: should scaling to more repos mean more Guild deployments (one per repo, one per org) or a single deployment that routes by repository? Kubernetes-per-repo is a common pattern in multi-tenant CI systems, but it multiplies operational cost linearly with the number of repositories and shares nothing (no shared queue, no shared audit log, no shared worker pool).

## Decision

A single Guild deployment handles **multiple repositories** by routing webhook events to configured workers through a **`repos` database table**.

The table schema is:

| Column | Type | Notes |
|---|---|---|
| `full_name` | string (unique) | GitHub repository full name, e.g. `"jhgaylor/guild"` |
| `enabled` | boolean | Whether this repo is actively processed; defaults to `true` |
| `worker_id` | string | References the worker row responsible for this repo |
| `inserted_at` / `updated_at` | utc_datetime_usec | Managed by Ecto |

When a webhook event arrives, the routing layer looks up the repository's `full_name` in the `repos` table. If a matching, enabled row is found, the event is dispatched to the corresponding worker. If no row exists, or the row is disabled, the event is discarded (or logged and ignored). This keeps the webhook surface unchanged — no new routes, no per-repo endpoints.

The default row seeded on first deploy is `full_name: "jhgaylor/guild", enabled: true, worker_id: <default_worker_id>`, preserving the current single-repo behavior for existing deployments.

## Alternatives Considered

- **One Kubernetes deployment per repository** — Each repo gets its own Guild instance with its own environment configuration. Provides strong isolation but multiplies operational cost (deployments, databases, monitoring, upgrades) linearly. Shared concerns (audit log, worker pool sizing, cross-repo insights) require out-of-band coordination. Rejected as premature and expensive for the scale Guild is currently at.

- **One deployment per organization, repos implicit** — A middle ground where each customer org gets a Guild instance but all repos in that org are handled implicitly. Avoids explicit per-repo configuration but still requires one database and one deployment per org. Does not compose cleanly with mixed-org deployments (a single Guild managing repos from multiple GitHub orgs). The explicit `repos` table handles this naturally.

- **Webhook fan-out via GitHub Apps** — Configure the GitHub App to deliver per-repo webhooks to per-repo endpoints. Keeps routing out of Guild's database but requires managing multiple webhook configurations and endpoint registrations. Adds external configuration complexity that the `repos` table avoids entirely.

## Consequences

- **`repos` table is created this slice.** A migration creates the table with the schema above. `Guild.Schema.Repo` is added as the corresponding Ecto schema module.
- **Webhook routing is not changed this slice.** The `repos` table is created and seeded, but the webhook handler is not yet updated to perform a database lookup. That wiring is deferred to keep this slice schema-only and non-breaking.
- **No Kubernetes or infrastructure changes.** The multi-repo architecture is purely a database configuration concern. Existing deployments continue to work without any changes to their hosting environment.
- **`worker_id` is a plain string reference.** There is no foreign-key constraint to the `workers` table in this slice, to keep migrations independent and the schema additive. Referential integrity can be enforced in a later migration once both tables are stable.
- **Enabled flag allows soft disabling.** A repo can be removed from active processing without deleting the row, preserving historical audit context.
