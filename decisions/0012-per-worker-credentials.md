# 0012 — Per-Worker Credentials

**Status:** Accepted

## Context

Guild currently dispatches all Fountain conversations using a single set of credentials read from environment variables: `GUILD_IMPLEMENTER_AGENT_ID` (the Fountain agent identifier) and `GUILD_WORKER_VAULT_ID` (the Vault credential set). A single GitHub App installation (`GITHUB_APP_INSTALLATION_ID`) covers all repository access. These environment variables are adequate for a single-worker deployment but break down as soon as more than one worker type or identity is needed.

Planned evolution includes workers with different capability profiles (e.g., a general-purpose implementer vs. a documentation-only writer), workers that act under different GitHub identities (e.g., a bot account scoped to a client org), and workers that use different Fountain agent configurations. Hardcoding a single identity in environment variables means every worker would share one Fountain agent and one vault, making per-worker access control, auditing, and rollout impossible.

## Decision

Worker credentials are stored in a **`workers` database table** that maps a `worker_id` (opaque string primary key) to the credentials that worker uses when dispatching Fountain conversations.

The table schema is:

| Column | Type | Notes |
|---|---|---|
| `worker_id` | string (PK) | Unique identifier for this worker configuration |
| `fountain_agent_id` | string | Fountain agent to dispatch as |
| `vault_id` | string | Vault credential set for this worker |
| `github_installation_id` | string (nullable) | GitHub App installation; falls back to global default if null |
| `inserted_at` / `updated_at` | utc_datetime_usec | Managed by Ecto |

At dispatch time, the worker process looks up its own row in the `workers` table (by `worker_id`) and uses the credentials found there rather than reading environment variables directly. The environment variables `GUILD_IMPLEMENTER_AGENT_ID` and `GUILD_WORKER_VAULT_ID` become **seed values**: on first deploy (or via `mix run priv/repo/seeds.exs`) they populate a default worker row, preserving backward compatibility with existing single-worker deployments.

## Alternatives Considered

- **Per-conversation credential switching** — Selecting credentials at conversation dispatch time based on the thread or repository being processed, rather than the worker identity. This would require Fountain to support mid-session credential switching or Guild to open a new conversation with different credentials on every context switch. Fountain does not currently support this, and adding it would require changes outside the Guild codebase.

- **Multiple env-var sets** — Extending the environment variable scheme with prefixed variable groups (e.g., `WORKER_A_FOUNTAIN_AGENT_ID`, `WORKER_B_VAULT_ID`). This avoids a database table but makes configuration opaque (not queryable, not auditable), couples the number of workers to the deployment configuration, and requires a redeploy to add or change a worker. The database table is discoverable, auditable, and changeable at runtime.

- **External secrets manager as the source of truth** — Storing worker credentials exclusively in HashiCorp Vault or a similar system and looking them up on every dispatch. This is operationally heavier than the current infrastructure warrants. The `workers` table can reference Vault identifiers (via `vault_id`) without replacing the database as the routing layer.

## Consequences

- **`workers` table is created this slice.** A migration creates the table with the schema above. `Guild.Schema.Worker` is added as the corresponding Ecto schema module.
- **Env vars become seed values, not runtime config.** `GUILD_IMPLEMENTER_AGENT_ID` and `GUILD_WORKER_VAULT_ID` are read by `priv/repo/seeds.exs` to insert a default worker row. Existing single-worker deployments continue to work without any configuration changes.
- **Dispatch code is not wired up this slice.** The `workers` table and schema are created, but the `ClaimWorker` and Fountain dispatch path are not yet updated to look up credentials from the table. That change is deferred to the next slice to keep this slice schema-only and risk-free.
- **`github_installation_id` nullable.** Workers that do not need a per-worker GitHub installation (e.g., all repos belong to the same org) leave this null; dispatch falls back to the global installation configured in the environment.
