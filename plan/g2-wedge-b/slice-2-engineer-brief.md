## Context
G2 Wedge B, Slice 2. Slice 1 merged (404d8ee). Base: main at 404d8ee.
ADRs 0002-0009 locked. Slice spec: plan/g2-wedge-b/slice-plan.md.

## Task
- lib/guild/state_machine.ex — transition/2 {:ok,state}|{:error,:illegal_transition};
  9 states; IllegalTransitionError; full transition table from engineering-plan
- lib/guild/startup_recovery.ex — recover/0 queries threads WHERE state in
  active_states() AND owner==worker_identity; logs; returns {:ok,count}; no re-dispatch
- lib/guild/context_assembly.ex — build/1: last 50 events (occurred_at DESC) +
  all context_notes where note_type=human_instruction; TODO(summarization) per ADR 0007
- lib/guild/worker/context_packet.ex — struct: work_item, history, artifacts,
  conversations, worker_notes, current_event
- lib/guild/worker/decision.ex — struct(action,reasoning,params); validate/1
  rejects nil/empty reasoning and illegal action atoms

## Acceptance
- mix test green (incl Slice 1 schema tests)
- StateMachine: every legal + every illegal transition tested explicitly
- ContextAssembly: 60-event fixture; assert history==50; all human_instruction notes present
- Decision validate/1: rejects empty reasoning; rejects invalid action atom

## Out of scope
- No Guild.GitHub, Fountain, or action primitive code
- StartupRecovery logs only — no re-dispatch
