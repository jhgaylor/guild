# 0004 — Worker execution via a runtime-agnostic adapter (Fountain first)

**Status:** Accepted

## Context

The architecture in [`docs/04-decision-layer.md`](../docs/04-decision-layer.md) and [`docs/05-action-primitives.md`](../docs/05-action-primitives.md) describes what a worker decides and what actions it can take, but is silent on where the code-generating agent loop physically runs. That loop needs an entire runtime — per-run sandboxing, repo mounting, env injection, MCP servers, multi-CLI dispatch (claude/codex/gemini/opencode), streaming output, and a verification gate before any PR opens.

[Fountain](https://fountain.inevitable.fyi) already does this and already runs on the same home-cloud cluster. The shape (`POST /api/conversations` → SSE stream → follow-up / interrupt / terminate) is what Guild wants to call. But the agent-execution market is moving fast: Anthropic shipped Managed Agents in 2026 with a near-identical API surface; OpenAI's Agents SDK is consolidating sandbox adapters; the run-an-agent abstraction is clearly real but no offering has obviously won. Picking one runtime today is partly a guess about which offering will still be the right call in 18 months.

We need to commit to a runtime before the wedge implementation without baking that bet into the Decision Layer.

## Decision

Guild dispatches code-generating execution through a **runtime-agnostic adapter** behind a small, named interface owned by [`docs/05-action-primitives.md`](../docs/05-action-primitives.md). The primitives are roughly `dispatch_conversation(prompt, agent_ref, environment, opts)`, `observe_conversation(id)`, `follow_up_prompt(id, prompt)`, `interrupt_conversation(id)`, `terminate_conversation(id)`. The Decision Layer returns dispatches in those terms and never references a specific runtime.

**The first adapter implementation backs onto Fountain.** The Sprite owns the full edit → verify → push → PR-open cycle inside its sandbox; Guild orchestrates the dispatch, observes the stream, persists state transitions, and manages social presence and threading around the run.

Two reasons stack:

1. **Fountain first** — same "dumbest version that lets a Guild worker use it" principle from [`OPERATING_MODEL.md`](../OPERATING_MODEL.md) that picked Postgres in [`0003`](0003-postgres-as-system-of-record.md). It already runs in the cluster, already speaks the right shape, no integration debt to ship before the wedge.
2. **Behind an adapter** — the runtime market is too young to bet the Decision Layer on one offering. The blast radius of being wrong about Fountain (or Managed Agents, or anything else) should be one adapter module, not the worker runtime.

## Consequences

- **Decision Layer outputs change shape.** A "go implement this" decision returns an adapter dispatch spec (prompt + agent_ref + environment), not raw git or GitHub calls. [`docs/04-decision-layer.md`](../docs/04-decision-layer.md) needs an update PR.
- **Action Primitives split.** Granular code primitives (`create_branch`, `commit_and_push`, `open_pull_request`, `push_to_branch`) live *inside* the Sprite, not at Guild's layer. Guild's primitives become the five adapter calls above plus the unchanged meta/presence/state primitives (`comment_on_issue`, `update_thread_state`, `log_decision`, …). [`docs/05`](../docs/05-action-primitives.md) needs a rework PR that also specifies the adapter interface.
- **Verification gate moves inside the Sprite.** The "must pass verification before `open_pull_request`" invariant ([`docs/05#verification-requirement`](../docs/05-action-primitives.md#verification-requirement)) is enforced by the agent loop inside the Sprite. Guild's gate becomes "did the conversation reach `completed` cleanly?" How Guild trusts that signal is a follow-up question worth its own ADR if it gets contentious.
- **Swap-cost is bounded.** Replacing Fountain with Anthropic Managed Agents (or any future offering that exposes a dispatch+stream API) is a new adapter module, not a Decision Layer rewrite. The cost of being wrong about Fountain is one file.
- **Hard runtime dependency on the configured adapter.** If Fountain is down, no workers run. Acceptable: they share a cluster, and Guild has no useful "degraded mode" without execution.

## Alternatives considered

- **Hardcoded Fountain integration, no adapter** — Saves the indirection but couples the Decision Layer to one runtime. If Fountain becomes unmaintained or the team picks a different runtime later, every worker definition gets rewritten. The indirection is cheap; the lock-in is not.
- **Anthropic Managed Agents as the only runtime** — Same shape (REST + SSE, environments + sessions), zero homebrew dependency, but cloud-only, Claude-only, and breaks the "self-hosting is the success metric" line in [`OPERATING_MODEL.md`](../OPERATING_MODEL.md). Stays viable as a second adapter implementation if Fountain stops earning its keep.
- **Direct model API calls from Guild** — Would reinvent every layer (sandboxing, repo mounting, MCP, multi-runtime, streaming) that the existing offerings already provide. Violates the "dumbest version" principle when the dumbest version is literally running already.
