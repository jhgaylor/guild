# G1 Wedge B — Engineering Plan Brief

## Context

G0 is resolved: Wedge B (thread model + state machine first, claiming stubbed) was selected by the operator.
Locked ADRs: 0002 (Elixir/Phoenix/LiveView), 0003 (Postgres/Ecto), 0004 (Fountain adapter).
Source of truth: `docs/01-event-stream.md` through `docs/08-work-claiming.md`.
The Fountain adapter interface exposes five primitives: `run_worker/2`, `send_prompt/2`, `stream_output/2`, `get_status/1`, `terminate/1`.

## Task

- Produce `plan/g1-wedge-b/engineering-plan.md` covering all load-bearing pieces of Wedge B:
  schemas (events, threads, artifacts, context_notes, decisions_log), full nine-state machine with
  transition table and crash-recovery column, worker decision contract (input/output structs +
  three error variants), action primitive surface with Fountain adapter mapping, `Guild.Tasks.ClaimSeed`
  spec (Mix task vs GenServer, justified), ADRs required before implementation, and open questions.
- Edit `ROADMAP.md`: move `phase-0-framing` out of Now (PR #1 merged, G0 resolved — Wedge B chosen),
  add `g1-wedge-b-plan` entry with this conversation ID.
- Open a PR against `main` titled `plan: G1 wedge-B engineering plan`.

## Acceptance

- [ ] `engineering-plan.md` covers all six top-level sections with required subsections
- [ ] Every schema has field names, types, and index notes
- [ ] State machine table covers all 9 states with crash-recovery column
- [ ] Worker decision contract shows input struct, output struct, and three error variants
- [ ] Action primitives map Fountain adapter calls explicitly
- [ ] ClaimSeed spec picks Mix task or GenServer and justifies the choice
- [ ] ADRs Required section is non-empty
- [ ] ROADMAP.md Now section updated; phase-0-framing moved out
- [ ] PR open against `main`

## Out of scope

- No .ex files, migrations, or mix.exs changes
- Do not write ADRs — only identify them
- Do not touch `docs/` — those are the source of truth
- Do not implement ClaimSeed — only spec it
- No UI/LiveView changes
