# G2 Slice Plan — Wedge B

> Produced by `general-purpose-engineer` on 2026-05-19. Awaiting operator review before any implementer is dispatched.

## Overview

G2 delivers the first runnable end-to-end path: a Phoenix/Ecto application with a complete thread model, nine-state machine, Fountain-backed worker dispatch, and a Mix task that claims issue #3, dispatches a Fountain conversation to write CONTRIBUTING.md, and opens a real PR. The work is decomposed into five strictly sequential slices; slices 1–4 use no real GitHub API calls (mockable boundary throughout), and slice 5 is the live E2E run that requires real GitHub App credentials and a provisioned Fountain setup. "Done" at G2 means Fountain reports `completed` cleanly, a PR exists on `jhgaylor/guild`, and the thread model contains a full audit trail of the run.

---

## Slice 1 — Phoenix Scaffold + Ecto + All Five Schemas

**Summary:** Create the Phoenix/Ecto application skeleton with all five database schemas, migrations, and indexes as specified in the engineering plan.

**In scope:**
- `mix phx.new guild --no-assets --no-gettext --no-mailer` scaffold
- `mix.exs` with deps: `ecto_sql`, `postgrex`, `phoenix`, `phoenix_live_view`, `jason`
- `lib/guild/repo.ex` — Ecto.Repo backed by Postgres
- `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/prod.exs` — DB URL, pool size, worker identity config key
- Five migrations under `priv/repo/migrations/`:
  - `..._create_events.exs` — all columns + indexes from engineering plan (thread_id+timestamp, source+type+timestamp, unique source+raw->>'id')
  - `..._create_threads.exs` — all columns + indexes (state, anchor_type+anchor_id unique, parent_thread_id, owner+state)
  - `..._create_artifacts.exs` — all columns + indexes (thread_id+artifact_type, source+external_id unique, artifact_type+metadata->>'state')
  - `..._create_context_notes.exs` — all columns + indexes (thread_id+inserted_at, thread_id+note_type)
  - `..._create_decisions_log.exs` — all columns + indexes (thread_id+inserted_at, decision_type+inserted_at, inserted_at); migration-level TODO comment per ADR 0009
- Five Ecto schema modules: `lib/guild/schema/event.ex`, `thread.ex`, `artifact.ex`, `context_note.ex`, `decisions_log.ex` — typed fields, changeset/2, no business logic

**Stubbed at this slice:**
- GitHub API: no calls; no behaviour defined yet
- State machine: no module; `threads.state` is a plain varchar field
- Fountain: not referenced

**Acceptance criteria:**
- `mix test` passes on a clean Postgres instance after `mix ecto.create && mix ecto.migrate`
- Tests assert each schema's changeset validates required fields and rejects illegal values
- Tests assert unique constraint violations on `(anchor_type, anchor_id)` for threads and `(source, external_id)` for artifacts
- `mix ecto.rollback --all` succeeds (migrations are reversible)

**Depends on:** (none)

**Brief estimate:** 22 lines

---

## Slice 2 — State Machine + Context Assembly + Worker Contracts

**Summary:** Implement the nine-state machine with crash-recovery, the bounded context assembly function, and the Worker.ContextPacket / Worker.Decision structs.

**In scope:**
- `lib/guild/state_machine.ex` — `transition/2` returning `{:ok, new_state}` or `{:error, :illegal_transition}`; all 9 states as atoms; `Guild.StateMachine.IllegalTransitionError` exception; full transition table from engineering plan encoded as a guard function
- `lib/guild/startup_recovery.ex` — `recover/0` queries `threads` where `state NOT IN ['done', 'abandoned'] AND owner = configured_worker_identity` (config key: `:guild, :worker_identity`); logs threads found; stub action per state (log only, no re-dispatch yet)
- `lib/guild/context_assembly.ex` — `build/1` takes a thread_id; fetches last 50 events ordered by `timestamp DESC`; fetches all `context_notes` with `note_type = 'human_instruction'` unconditionally; assembles into `%Guild.Worker.ContextPacket{}`; `# TODO(summarization): revisit when thread length forces it` comment
- `lib/guild/worker/context_packet.ex` — `%Guild.Worker.ContextPacket{}` struct with all fields from engineering plan (work_item, history, artifacts, conversations, worker_notes, current_event)
- `lib/guild/worker/decision.ex` — `%Guild.Worker.Decision{}` struct (action, reasoning, params); `validate/1` rejects nil or empty reasoning, returns `{:error, :missing_reasoning}`

**Stubbed at this slice:**
- GitHub API: no calls
- Fountain: not referenced
- Startup recovery dispatches nothing — logs only

**Acceptance criteria:**
- `mix test test/guild/state_machine_test.exs` passes
- State machine tests cover every legal transition in the table and every illegal transition (assert `{:error, :illegal_transition}` for each)
- `mix test test/guild/context_assembly_test.exs` passes with seeded DB fixture (thread + 60 events + 3 human_instruction notes); assert exactly 50 history entries and all 3 notes appear in the packet
- `mix test test/guild/worker/decision_test.exs` passes; assert `validate/1` rejects empty reasoning

**Depends on:** Slice 1 merged

**Brief estimate:** 26 lines

---

## Slice 3 — Action Primitives + Fountain Adapter (GitHub Behind Behaviour)

**Summary:** Implement all 24 action primitives with GitHub-touching ones behind a behaviour + TestAdapter, and implement the Fountain adapter module backed by the real Fountain HTTP API.

**In scope:**
- `lib/guild/github.ex` — behaviour module declaring callbacks for every GitHub-touching primitive: `assign_to_self/2`, `comment_on_issue/3`, `comment_on_pr/3`, `create_branch/3`, `commit_and_push/4`, `open_pull_request/5`, `update_pull_request/3`, `push_to_branch/4`, `create_issue/6`, `create_sub_issue/5`, `update_issue/3`, `close_issue/3`, `add_to_project/3`, `update_issue_status/3`, `add_label/3`
- `lib/guild/github/test_adapter.ex` — `@behaviour Guild.GitHub`; all callbacks return configurable `{:ok, _}` or error tuples; no HTTP calls
- Action primitive modules (each returns typed error tuples per ADR 0008):
  - `lib/guild/actions/code.ex` — `create_branch/3`, `commit_and_push/4`, `open_pull_request/5`, `update_pull_request/3`, `push_to_branch/4` (delegate to `Guild.GitHub` impl)
  - `lib/guild/actions/planning.ex` — `create_issue/6`, `create_sub_issue/5`, `update_issue/3`, `close_issue/3`, `add_to_project/3` (delegate to `Guild.GitHub` impl; Linear stubs return `{:error, :permanent, :linear_not_configured}`)
  - `lib/guild/actions/communication.ex` — `comment_on_issue/3`, `comment_on_pr/3` (delegate to `Guild.GitHub` impl); `reply_in_thread/3`, `post_to_channel/2` (stub: `{:error, :permanent, :slack_not_configured}`)
  - `lib/guild/actions/work_management.ex` — `assign_to_self/2`, `update_issue_status/3`, `add_label/3` (delegate to `Guild.GitHub` impl)
  - `lib/guild/actions/meta.ex` — `write_thread_note/4`, `update_thread_state/2`, `log_decision/3` (Postgres only; call `Guild.StateMachine.transition/2` inside `update_thread_state/2`)
- `lib/guild/adapters/fountain.ex` — implements five primitives: `dispatch_conversation/4` (POST `/api/conversations`), `send_prompt/2` (follow-up POST), `observe_conversation/1` (SSE stream via HTTPoison), `get_status/1` (GET conversation status), `terminate_conversation/1` (DELETE/terminate call); reads `FOUNTAIN_BASE_URL` and `FOUNTAIN_TOKEN` from config; error responses mapped to three-tier taxonomy per ADR 0008

**Stubbed at this slice:**
- GitHub API: all calls go through `Guild.GitHub` behaviour; tests configure `Guild.GitHub.TestAdapter`
- Fountain: real HTTP implementation, but tests use a local Bypass mock server for HTTP calls

**Acceptance criteria:**
- `mix test test/guild/actions/` passes with `Guild.GitHub.TestAdapter` configured in `test.exs`
- Tests cover `{:ok, _}` and each error tier (`{:error, :transient, _}`, `{:error, :permanent, _}`, `{:error, :unexpected, _}`) for every primitive
- `mix test test/guild/adapters/fountain_test.exs` passes with Bypass mock; asserts correct HTTP calls for each of the five adapter functions
- `mix test test/guild/actions/meta_test.exs` covers `update_thread_state/2` rejecting illegal transitions (delegates to state machine)

**Depends on:** Slice 2 merged

**Brief estimate:** 29 lines

---

## Slice 4 — ClaimSeed Mix Task + Guild Implementer Agent Spec

**Summary:** Implement `Guild.Tasks.ClaimSeed` and commit the Guild implementer worker spec at `agents/guild-implementer.yml`.

**In scope:**
- `lib/mix/tasks/guild/claim_seed.ex` (`mix guild.claim_seed`) — accepts `--repo` and `--issue-number`; executes the seven-step sequence from the engineering plan: fetch issue via `Guild.GitHub` impl, upsert thread, `unnoticed → noticed → claimed` via state machine, `assign_to_self`, `comment_on_issue`, insert seed event, print thread_id; reads `GITHUB_TOKEN` from env and `:guild, :worker_identity` from config
- `agents/guild-implementer.yml` — the Guild implementer worker spec inside the repo at this path; contains: agent name (`guild-implementer`), runtime hint (`fountain`), repo scope (`jhgaylor/guild`), system prompt reference, tool permissions; **path chosen: `agents/guild-implementer.yml`**
- `test/mix/tasks/guild/claim_seed_test.exs` — uses `Guild.GitHub.TestAdapter` (configured via application env in test); asserts thread row created with correct anchor fields; asserts state transitions recorded; asserts seed event inserted; asserts exit 0 on success and exit 1 with printed reason on GitHub fetch failure

**Stubbed at this slice:**
- GitHub API: `Guild.GitHub.TestAdapter` in test; real adapter not yet wired (no `lib/guild/github/http_adapter.ex`)
- Fountain: not invoked by ClaimSeed itself (dispatch happens after claiming, not in this task's scope for this slice)

**Acceptance criteria:**
- `mix test test/mix/tasks/guild/claim_seed_test.exs` passes
- Tests assert idempotency: running ClaimSeed twice on the same issue produces one thread row (upsert semantics verified)
- Tests assert that a missing `--repo` or `--issue-number` argument prints usage and exits 1
- `agents/guild-implementer.yml` exists and is valid YAML (`mix run -e "File.read!(\"agents/guild-implementer.yml\") |> YamlElixir.read_from_string!()"` or equivalent)

**Depends on:** Slice 3 merged

**Brief estimate:** 20 lines

---

## Slice 5 — E2E Happy Path: Issue #3 (Real GitHub + Real Fountain)

**Summary:** Wire the real GitHub HTTP adapter, run `mix guild.claim_seed` against issue #3, trigger a Fountain conversation with `agents/guild-implementer.yml` as the agent spec, and verify that Fountain completes cleanly with a PR open on `jhgaylor/guild`.

**Prerequisites (must be provisioned before this slice begins):**
- GitHub App credentials: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_INSTALLATION_ID` (or `GITHUB_TOKEN` with `contents:write`, `issues:write`, `pull_requests:write` scopes on `jhgaylor/guild`)
- Fountain setup: `FOUNTAIN_BASE_URL` and `FOUNTAIN_TOKEN` pointing to a running Fountain instance with the `guild-implementer` agent spec loaded
- `agents/guild-implementer.yml` accessible to Fountain at the configured agent ref

**In scope:**
- `lib/guild/github/http_adapter.ex` — `@behaviour Guild.GitHub`; implements all 15 callbacks using `HTTPoison` + GitHub REST API v3; reads `GITHUB_TOKEN` from env; maps HTTP responses to three-tier error taxonomy per ADR 0008
- `config/runtime.exs` — wire `Guild.GitHub.HttpAdapter` as the configured impl when `GITHUB_TOKEN` is set; fall back to `Guild.GitHub.TestAdapter` otherwise
- `test/e2e/claim_seed_e2e_test.exs` — tagged `@tag :e2e`; excluded from default `mix test`; run with `mix test --include e2e`; asserts: thread row created with `anchor_id` matching issue #3's node_id; state transitions `unnoticed → noticed → claimed` in DB; Fountain conversation dispatched (artifact row with `artifact_type: "fountain_conversation"`); Fountain `get_status/1` eventually returns `completed`; PR artifact row exists with a valid URL

**Stubbed at this slice:**
- Nothing — this is the live run

**Acceptance criteria:**
- `mix test --exclude e2e` still passes (non-E2E suite unaffected by credential wiring)
- `mix test --include e2e test/e2e/claim_seed_e2e_test.exs` passes with real credentials in env
- A PR exists on `jhgaylor/guild` opened by the configured worker identity, containing `CONTRIBUTING.md` satisfying issue #3's acceptance criteria
- Fountain conversation status is `completed` (no `verification_passed` field inspected — clean completion is the gate per ADR 0004)
- Thread row in DB has state `pr_open` with a `pull_request` artifact linking to the opened PR

**Depends on:** Slice 4 merged

**Brief estimate:** 18 lines
