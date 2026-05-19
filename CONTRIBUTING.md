# Contributing to Guild

## For Humans

All changes must arrive via pull request against `main`. Direct pushes to `main` are not permitted.

Before contributing, read `OPERATING_MODEL.md` to understand how the project is governed — it defines roles, process gates, and working principles that apply to every change.

Significant architectural choices must be recorded as Architecture Decision Records (ADRs) in the `decisions/` folder. Copy `decisions/0001-template.md` as `decisions/NNNN-<short-title>.md` and fill it in before opening a PR that introduces a meaningful technical decision.

## For Autonomous Workers

Start every session by reading `OPERATING_MODEL.md`. It is the authoritative source of governance, role definitions, and working agreements. Anything not covered there should be treated as unspecified, not as permitted.

Every code change must satisfy the verification requirements described in `docs/05-action-primitives.md`. The `open_pull_request` primitive cannot execute until automated verification passes — no exceptions. Verification must be fully automatable; human judgment does not count as verification.

Only the orchestrator opens pull requests to `main`. Specialist workers implement changes and hand off to the orchestrator; they do not open PRs directly.

## Repo Map

| Path | Description |
|------|-------------|
| `OPERATING_MODEL.md` | Governance bible — roles, process gates, and working principles read by the orchestrator every cycle |
| `ROADMAP.md` | Live roadmap tracking current work, upcoming items, and gated milestones |
| `docs/` | Sequential technical architecture docs covering the event stream, thread model, context assembly, decision layer, action primitives, state machine, social presence, and work claiming |
| `decisions/` | Numbered Architecture Decision Records (ADRs) documenting significant technical choices |
| `plan/` | Phase-based engineering plans organized by development milestone (g1, g2, etc.) |
| `discovery/` | Early-phase framing and research documents produced before formal planning begins |
