# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Orchestrator

- captain-picard — conv `a42b667b-260d-44f1-8779-7d33da89cd06` (kicked off 2026-05-19 for phase-0-framing). Resume with `fountain conv prompt a42b667b-260d-44f1-8779-7d33da89cd06 -p "..."` — never start a fresh `fountain run` while this is active.

## Now

_(empty — G2 closed; next is G3 deliberation)_

## Done

- **phase-0-framing** — PR #1 merged. G0 resolved: Wedge B selected.
- **g1-wedge-b-plan** — PR #2 merged (4d7cf34). Engineering plan locked.
- **g1-adrs** — PR #4 merged (73e4155). ADRs 0005–0009 locked.
- **g2-slice-plan** — PR #5 merged (b94d49d). G2 slice decomposition locked.
- **g2-slice-1** — PR #6 merged (404d8ee). Phoenix scaffold + Ecto + all five schemas.
- **g2-slice-2** — PR #7 merged (ac885d6). State machine + context assembly + worker contracts.
- **g2-slice-3** — PR #8 merged (5bcbdb0). Action primitives + Fountain adapter.
- **g2-slice-4** — PRs #9+#10 merged (da3f05a/9da21e3). ClaimSeed + implementer agent registered.
- **g2-slice-5** — PRs #11+#13 merged (88da670/ab6f576). HttpAdapter + E2E test with reconciliation.
- **g2-infra** — PR #12 merged (6be8635) + fixes 220a719/79b979c/64cbf43/8ad297b. Phoenix release Dockerfile + k8s wiring + SSL/assign/timeout patches.
- **g2-e2e** — **G2 success metric hit (2026-05-19).** PR #14 merged (e850809). Worker (Fountain conv `933fbc59`, terminated) claimed issue #3, implemented CONTRIBUTING.md, verified with `mix test` (227 passing), opened PR. Driver merged. Full claim → PR → merge cycle proved with thread continuity. `guild.inevitable.fyi` serves the Phoenix app.

## Next

_(empty — pending G3 framing)_

## Gated

- **G0** — resolved. Wedge B selected.
- **G1** — CLOSED. ADRs 0005–0009 merged (PR #4, 73e4155).
- **G2** — CLOSED. Worker shipped PR #14 against issue #3, merged 2026-05-19.
- **G3** — Self-hosting cutover: point the worker at live issues in this repo.
