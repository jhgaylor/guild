# 0004 — Fountain Sprites execute Guild workers

**Status:** Accepted

## Context

The architecture in [`docs/04-decision-layer.md`](../docs/04-decision-layer.md) and [`docs/05-action-primitives.md`](../docs/05-action-primitives.md) describes what a worker decides and what actions it can take, but is silent on where the code-generating agent loop physically runs. A worker that's asked to implement an issue needs to: spin up an isolated environment, mount the right repos and credentials, drive an LLM CLI (claude, codex, …) in a loop, run verification, push commits, open a PR. That is itself an entire runtime — sandboxing, repo mounting, MCP, skills, multi-CLI dispatch, streaming output.

[Fountain](https://fountain.inevitable.fyi) already does this. It runs on the same home-cloud cluster as Guild, exposes a bearer-token API for `POST /api/conversations`, provisions a per-conversation isolated Sprite, mounts a configured Environment (repos + env + MCP + skills), runs the chosen runtime CLI in it, and streams output over SSE. The Sprite is fully capable of running git, `gh`, and verification inside the sandbox.

We need to commit to where worker execution happens before [`docs/04`](../docs/04-decision-layer.md) and [`docs/05`](../docs/05-action-primitives.md) get reworked, because the boundary determines what is even *expressible* as a Decision Layer return value or Action Primitive.

## Decision

**Guild workers dispatch code-generating execution to Fountain.** The Decision Layer's coding-related outputs are Fountain conversation dispatches (`agent_id` + `prompt` + Environment/Vault selection), not raw git or GitHub calls. The Sprite owns the **full edit → verify → push → PR-open cycle** inside its sandbox. Guild's role is orchestration: dispatch the conversation, observe via SSE or polling, persist state transitions, and manage social presence (issue/PR comments, thread linkage) around the run.

The load-bearing reason is the same **"dumbest version that lets a Guild worker use it"** principle from [`OPERATING_MODEL.md`](../OPERATING_MODEL.md) that picked Postgres in [`0003`](0003-postgres-as-system-of-record.md): Fountain already exists, already runs in this cluster, and already solves the agent-runtime problem. Building an in-process agent loop in Guild duplicates infrastructure we operate ten meters away. Self-hosting is preserved — Fountain is part of the same home-cloud.

## Consequences

- **Decision Layer outputs change shape.** A "go implement this" decision returns a Fountain dispatch spec (agent + prompt + environment + vault), not a `create_branch` + `commit_and_push` + `open_pull_request` sequence. [`docs/04-decision-layer.md`](../docs/04-decision-layer.md) needs an update PR.
- **Action Primitives split.** The granular code primitives in [`docs/05-action-primitives.md`](../docs/05-action-primitives.md) — `create_branch`, `commit_and_push`, `open_pull_request`, `push_to_branch` — live *inside* the Sprite (executed by the agent CLI), not at Guild's layer. Guild's primitives become: `dispatch_conversation`, `follow_up_prompt`, `interrupt_conversation`, `terminate_conversation`; plus the unchanged meta/presence/state primitives (`comment_on_issue`, `update_thread_state`, `log_decision`, …). [`docs/05`](../docs/05-action-primitives.md) needs a rework PR.
- **Verification gate moves inside the Sprite.** The "must pass verification before `open_pull_request`" invariant ([`docs/05#verification-requirement`](../docs/05-action-primitives.md#verification-requirement)) is now enforced by the agent loop *inside* the Sprite — the Sprite runs the tests and only invokes `gh pr create` on success. Guild's gate becomes "did the Fountain conversation reach `completed` with a non-failure exit?" How Guild trusts that signal (and what it does if a Sprite opens a PR despite failing verification) is a follow-up question worth its own ADR if it gets contentious.
- **Worker definitions reference Fountain Agents.** A Guild worker is now partly a Fountain Agent (runtime, model, prompt, skills, MCP) + the Guild-side wrapper (when to dispatch, how to thread events, how to persist state). The provisioning story for "create a new worker" includes creating its Fountain Agent.
- **Hard dependency.** If Fountain is down, no Guild worker runs. Acceptable: they share the same cluster, and Guild has no useful "degraded mode" without execution.

## Alternatives considered

- **Direct Claude API calls from Guild** — Guild's BEAM processes call Anthropic's API directly and run the agent loop in-process. Would reinvent every layer Fountain already provides: sandboxing, per-run isolation, repo mounting, MCP servers, multi-runtime support, streaming. Violates the "dumbest version" principle when the dumbest version is literally running already.
