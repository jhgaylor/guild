# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Orchestrator

- captain-picard — conv `a42b667b-260d-44f1-8779-7d33da89cd06` (kicked off 2026-05-19 for phase-0-framing). Resume with `fountain conv prompt a42b667b-260d-44f1-8779-7d33da89cd06 -p "..."` — never start a fresh `fountain run` while this is active.

## Now

- g1-adrs — general-purpose-engineer (conv cd480714-29b0-46cc-821e-1d6331c366c7)

## Done

- **phase-0-framing** — PR #1 merged. G0 resolved: Wedge B selected.
- **g1-wedge-b-plan** — PR #2 merged (4d7cf34). Engineering plan locked.

## Next

_(empty)_

- G1 gates when the ADR PR merges; G2 dispatch follows immediately after.

## Gated

- **G0** — resolved. Wedge B selected.
- **G1** — plan locked (PR #2). ADRs 0005–0009 in flight (decisions/g1-adrs branch). Gates when ADR PR merges.
- **G2** — First worker shippable end-to-end in a sandbox against a seeded issue.
- **G3** — Self-hosting cutover: point the worker at live issues in this repo.
