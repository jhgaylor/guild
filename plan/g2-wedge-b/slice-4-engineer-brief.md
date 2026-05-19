## Context
G2 Wedge B, Slice 4. Slice 3 merged (5bcbdb02). Base: main at 5bcbdb02.
ADRs 0002-0009 locked. Slice spec: plan/g2-wedge-b/slice-plan.md.

## Task
- lib/mix/tasks/guild.claim_seed.ex (mix guild.claim_seed --repo X --issue-number N):
  7-step sequence: fetch issue via Guild.GitHub → upsert thread with on_conflict
  (anchor_type,anchor_id unique) → :unnoticed→:noticed→:claimed via StateMachine →
  assign_to_self → comment_on_issue "Taking this — will open a PR when ready." →
  insert seed event → print thread_id; exit 1 on any error
- All GitHub calls through Guild.GitHub behaviour (TestAdapter in tests)
- Idempotency: double-run same --repo+--issue-number = one thread row
- agents/guild-implementer.yml — Fountain agent spec at repo root; system prompt
  equips worker to read GitHub issue, implement fix, run mix test (verification gate),
  open PR; must parse as valid YAML

## Acceptance
- mix test green (incl. prior slices)
- Double-run creates exactly one thread row (upsert idempotency verified)
- Missing --repo or --issue-number exits 1
- agents/guild-implementer.yml parses as valid YAML

## Out of scope
- No real GitHub HTTP adapter (Slice 5)
- No Fountain dispatch (Slice 5 wires E2E)
- No Phoenix controller or LiveView changes
