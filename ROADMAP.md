# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Orchestrator

- captain-picard — conv `a42b667b-260d-44f1-8779-7d33da89cd06` (kicked off 2026-05-19 for phase-0-framing). Resume with `fountain conv prompt a42b667b-260d-44f1-8779-7d33da89cd06 -p "..."` — never start a fresh `fountain run` while this is active.

## Now

- g2-slice-5 — general-purpose-engineer (conv $FOUNTAIN_CONVERSATION_ID)

## Done

- **phase-0-framing** — PR #1 merged. G0 resolved: Wedge B selected.
- **g1-wedge-b-plan** — PR #2 merged (4d7cf34). Engineering plan locked.
- **g1-adrs** — PR #4 merged (73e4155). ADRs 0005–0009 locked.
- **g2-slice-plan** — PR #5 merged (b94d49d). G2 slice decomposition locked.
- **g2-slice-1** — PR #6 merged (404d8ee). Phoenix scaffold + Ecto + all five schemas.
- **g2-slice-2** — PR #7 merged (ac885d64). State machine + context assembly + worker contracts.
- g2-slice-3 — PR #8 merged (5bcbdb02)
- g2-slice-4 — PRs #9+#10 merged (da3f05a/9da21e3). Fountain env+agent registered.

## Next

_(empty)_

- G1 gates when the ADR PR merges; G2 dispatch follows immediately after.

## Gated

- **G0** — resolved. Wedge B selected.
- **G1** — CLOSED. ADRs 0005–0009 merged (PR #4, 73e4155).
- **G2** — First worker shippable end-to-end in a sandbox against a seeded issue.
- **G3** — Self-hosting cutover: point the worker at live issues in this repo.
