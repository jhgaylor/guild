# Slice 3 Engineer Brief — Action Primitives + Fountain Adapter

## Context
G2 Wedge B, Slice 3. Slice 2 merged (ac885d64). Base: main at ac885d64.
ADRs 0002-0009 locked. Slice spec: plan/g2-wedge-b/slice-plan.md.

## Deliverables
- `lib/guild/github.ex` — behaviour with 15 callbacks
- `lib/guild/github/test_adapter.ex` — configurable test double, no HTTP
- `Guild.Primitives.{Code,Planning,Communication,WorkManagement,Meta}` — 24 primitives
- `lib/guild/adapters/fountain.ex` — 5 HTTP calls via HTTPoison
- Tests: all three error tiers per primitive; Fountain via Bypass mock

## Key Contracts
- All primitives return `{:ok, _}` | `{:error, :transient|:permanent|:unexpected, term()}`
- Error tier mapping per ADR 0008 canonical table
- `update_thread_state/2` delegates to `Guild.StateMachine.transition/2`
- Fountain: reads `FOUNTAIN_BASE_URL` + `FOUNTAIN_TOKEN` from config/env
- Linear/Slack stubs return `{:error, :permanent, :not_configured}`

## Out of Scope
- Real GitHub HTTP adapter (Slice 5)
- ClaimSeed Mix task (Slice 4)
- E2E wiring
