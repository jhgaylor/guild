## Context
G2 Wedge B, Slice 1. G1 locked (ADRs 0002–0009, plan/g1-wedge-b/engineering-plan.md).
Wedge B: thread model + state machine first, claiming stubbed to one seeded issue.
Base: b94d49ddf2e976b95bf46eeebb7d91daba54b33a (main). Slice spec: plan/g2-wedge-b/slice-plan.md.

## Task
- Phoenix scaffold: `mix phx.new guild --no-assets --no-gettext --no-mailer`
- `mix.exs` deps: ecto_sql, postgrex, phoenix, phoenix_live_view, jason
- `lib/guild/repo.ex` — Ecto.Repo
- `config/{config,dev,test,prod}.exs` — DB URL, pool, `:guild, :worker_identity` config key
- Five migrations: events, threads (anchor_type+anchor_id unique, parent_thread_id),
  artifacts (source+external_id unique), context_notes,
  decisions_log (TODO(retention) comment per ADR 0009)
- Five schema modules `lib/guild/schema/{event,thread,artifact,context_note,decisions_log}.ex`
  — typed fields, changeset/2, no business logic

## Acceptance
- `mix test` passes on clean Postgres after `mix ecto.create && mix ecto.migrate`
- Changeset tests: required fields validated, illegal values rejected
- Unique constraint tests: (anchor_type, anchor_id) on threads; (source, external_id) on artifacts
- `mix ecto.rollback --all` succeeds (reversible migrations)
- No state machine, GitHub, or Fountain code

## Out of scope
- No state machine, context assembly, or worker struct modules
- No Guild.GitHub behaviour or any HTTP calls
- No Fountain adapter
- No LiveView controllers/templates beyond scaffold boilerplate
