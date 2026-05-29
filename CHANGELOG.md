# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [G4] - 2026-05-29

Hardening and capability expansion for unattended operation. All 8 framing items shipped across 6 slices (PRs #27–#33).

### Added

- **Durable claim queue** via Oban (ADR-0010): `ClaimWorker` on `:claims` queue with args-unique deduplication and retry-with-backoff; webhook handler enqueues via `Oban.insert` and returns 200 immediately.
- **Slack adapter** (`Guild.Adapters.Slack`): posts messages on `:pr_open` and `:done` events; graceful no-op when credentials are absent.
- **Linear adapter** (`Guild.Adapters.Linear`): GraphQL create/update integration; persists `linear_issue_id` on threads; workflow state UUIDs configurable via environment variables; graceful no-op when credentials are absent.
- **Multi-worker support** via `workers` configuration table (ADR-0011, ADR-0012): per-worker credentials resolved at runtime; environment variables serve as seed values.
- **Multi-repo support** via `repos` routing table (ADR-0013): webhook routes resolved by `repos` table to `worker_id`; unconfigured or disabled repos are logged and ignored.
- **`decisions_log` retention** (ADR-0009): retains the most recent 200 decisions per thread; `context_snapshot` nulled on older rows (`Guild.Retention`).
- **Context summarization** (ADR-0007): summarizes via Fountain past the 50-note threshold; superseded notes archived (`Guild.Summarization`).
- `Guild.Release.seed/0` wired into the Dockerfile entrypoint to populate default `workers`/`repos` rows on fresh deploys.

### Changed

- **`SECRET_KEY_BASE`** sourced from Secrets at runtime with fail-fast behavior on missing value.
- Claiming pipeline threads `worker_id` through `Guild.Claiming`; CAS-claims `threads.owner` inside the advisory-lock transaction (0 rows updated → `{:cancel, :already_claimed}`).
- Fountain dispatch resolves `fountain_agent_id` and `vault_id` per worker from the `workers` table, with environment variable fallback.

### Fixed

- **Duplicate-dispatch race condition** resolved via PostgreSQL advisory locks combined with `threads.owner` compare-and-swap (CAS) operations.
- **Operator UI auth bypass** closed: `GuildWeb.OperatorAuth` `on_mount` guard added to `live_session`, closing the `/live` WebSocket path that previously bypassed HTTP Basic authentication.
- Operator UI HTTP Basic Auth credentials moved to a request-time function plug; prior compile-time `Plug.BasicAuth` opts baked `nil` into the release router.

### Security

- Operator UI (`/threads`, `/decisions`, `/threads/:id`) protected by HTTP Basic authentication.
- LiveView socket (`/live`) requires authenticated session via `on_mount` guard — previously unprotected.
