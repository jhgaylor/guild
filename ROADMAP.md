# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Orchestrator

- captain-picard — conv `a42b667b-260d-44f1-8779-7d33da89cd06` (kicked off 2026-05-19 for phase-0-framing). Resume with `fountain conv prompt a42b667b-260d-44f1-8779-7d33da89cd06 -p "..."` — never start a fresh `fountain run` while this is active.

## Now

- g1-wedge-b-plan — general-purpose-engineer (conv df0d8c26-04fe-40fe-a175-63ce2a379d15)

## Next

_(empty)_

## Done

- **phase-0-framing** — merged PR #1 (2026-05-19). G0 resolved: Wedge B chosen (thread model + state machine first, claiming stubbed).

## Gated

- **G0** — resolved. Wedge B selected.
- **G1** — Wedge plan + ADRs locked (event ingestion path, thread linkage, state persistence, action primitive runtime, worker decision contract). Runtime ADR already locked: [`decisions/0002-elixir-phoenix-liveview.md`](decisions/0002-elixir-phoenix-liveview.md).
- **G2** — First worker shippable end-to-end in a sandbox against a seeded issue.
- **G3** — Self-hosting cutover: point the worker at live issues in this repo.
