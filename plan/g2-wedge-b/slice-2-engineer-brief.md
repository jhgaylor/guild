# G2 Slice 2 — Engineer Brief
# State Machine + Context Assembly + Worker Contracts

**Produced by:** general-purpose-engineer  
**Date:** 2026-05-19  
**Branch:** g2/slice-2-state-machine  
**Base commit:** 404d8ee73d3d0e27451891f27dd4a8ed1a0da305 (main, Slice 1 merged)

---

## Summary

Slice 2 adds the nine-state machine, crash-recovery startup scan, bounded context assembly,
and the Worker contract structs (ContextPacket + Decision). No GitHub API calls. No Fountain
adapter. No action primitive implementations. StartupRecovery logs only — no re-dispatch.

---

## Deliverables

| File | Purpose |
|------|---------|
| `lib/guild/state_machine.ex` | `transition/2`, `active_states/0`, `IllegalTransitionError` |
| `lib/guild/startup_recovery.ex` | `recover/0` — log non-terminal owned threads on startup |
| `lib/guild/context_assembly.ex` | `build/1` — assemble ContextPacket from DB |
| `lib/guild/worker/context_packet.ex` | `%Guild.Worker.ContextPacket{}` struct |
| `lib/guild/worker/decision.ex` | `%Guild.Worker.Decision{}` struct + `validate/1` |
| `test/guild/state_machine_test.exs` | All legal + illegal transitions tested |
| `test/guild/context_assembly_test.exs` | 60-event fixture; assert 50 history, all notes |
| `test/guild/worker/decision_test.exs` | validate/1 rejects nil/empty reasoning, illegal action |
| `test/guild/startup_recovery_test.exs` | DB fixture; assert {:ok, 2} |

---

## State Machine

### States (atoms)

`:unnoticed`, `:noticed`, `:claimed`, `:executing`, `:planned`, `:pr_open`, `:blocked`,
`:done`, `:abandoned`

### Transition Table

| From | Event | To |
|------|-------|----|
| `:unnoticed` | `:event_ingested` | `:noticed` |
| `:noticed` | `:claim` | `:claimed` |
| `:noticed` | `:ignore` | `:unnoticed` |
| `:claimed` | `:dispatch` | `:executing` |
| `:executing` | `:pr_opened` | `:pr_open` |
| `:executing` | `:decomposed` | `:planned` |
| `:executing` | `:ask_question` | `:blocked` |
| `:pr_open` | `:changes_requested` | `:executing` |
| `:pr_open` | `:pr_merged` | `:done` |
| `:blocked` | `:human_replied` | `:executing` |
| `:planned` | `:all_children_done` | `:done` |
| any active | `:abandon` | `:abandoned` |

Active states (non-terminal): `unnoticed, noticed, claimed, executing, pr_open, blocked, planned`  
Terminal states: `done, abandoned`

### API

```elixir
transition(current_state :: atom(), event :: atom()) :: {:ok, atom()} | {:error, :illegal_transition}
active_states() :: [atom()]
```

`IllegalTransitionError` is defined for callers who prefer raise semantics; `transition/2` itself
returns tuples.

---

## StartupRecovery

`recover/0` queries `threads` where `state IN active_states()` AND `owner == configured worker
identity` (`:guild, :worker_identity`). Logs each found thread via `Logger.info/1`. Returns
`{:ok, count}`. No GenServer. No re-dispatch. No state transitions.

---

## ContextAssembly

`build/1` accepts a `thread_id` (UUID string).

1. Fetch thread row — return `{:error, :thread_not_found}` if missing
2. Query last 50 events ordered by `occurred_at DESC` (limit 50) — `history`
3. Query ALL context_notes where `note_type = "human_instruction"` — `worker_notes`
4. Return `{:ok, %Guild.Worker.ContextPacket{}}`

A `# TODO(summarization): revisit when thread length forces it — see decisions/0007` comment
sits above the `limit: 50` query per ADR 0007.

---

## Worker Contracts

### ContextPacket fields

```elixir
:work_item      # map: anchor_type, anchor_id, state, owner
:history        # [Event] up to 50
:artifacts      # [] stub for Slice 2
:conversations  # [] stub for Slice 2
:worker_notes   # [ContextNote] all human_instruction notes
:current_event  # triggering Event struct or nil
```

### Decision validate/1

```elixir
validate(%Decision{reasoning: nil})   -> {:error, :missing_reasoning}
validate(%Decision{reasoning: ""})    -> {:error, :missing_reasoning}
validate(%Decision{action: bad})      -> {:error, :invalid_action}  # not in @valid_actions
validate(%Decision{} = d)             -> {:ok, d}
```

Valid actions: `:implement, :plan, :ask_question, :comment, :claim, :ignore, :escalate`

---

## Acceptance Criteria

- `mix test` green (Slice 1 schema tests + all Slice 2 tests)
- StateMachine: every legal transition asserted; illegal transitions return
  `{:error, :illegal_transition}`
- ContextAssembly: 60-event fixture → exactly 50 history; all 3 human_instruction notes present
- Decision `validate/1`: rejects nil reasoning, empty string reasoning, illegal action atom

---

## Out of Scope

- No Guild.GitHub behaviour or HTTP calls
- No Fountain adapter
- No action primitive implementations (Slice 3)
- StartupRecovery logs only — no re-dispatch

---

## ADR References

- `decisions/0007-context-assembly-strategy.md` — bounded window, TODO comment mandate
- `decisions/0006-thread-linkage-resolution.md` — explicit-only; unlinked events ok
- `plan/g1-wedge-b/engineering-plan.md` — full transition table, ContextPacket fields
