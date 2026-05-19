# 0002 — Build Guild on Elixir, Phoenix, and LiveView

**Status:** Accepted

## Context

Guild is a platform for autonomous workers: long-lived agents that hold per-thread state, react to events from GitHub/Slack/Discord, and exercise judgment over time. The architecture in [`docs/`](../docs/) — normalized event stream, thread model, context assembly, decision layer, action primitives, state machine, social presence, work claiming — is fundamentally a runtime for many concurrent, supervised, stateful agents communicating with the outside world. The success metric ([`OPERATING_MODEL.md`](../OPERATING_MODEL.md)) is Guild running a worker against its own repo, which means the runtime has to be durable enough to host real, long-running agent loops, not just dispatch one-shot jobs.

We need to commit to a primary language and web stack before the wedge implementation starts so ADRs about queues, state stores, and action runners can be written against a concrete runtime rather than in the abstract.

## Decision

Guild is built on **Elixir**, with **Phoenix** as the web framework and **LiveView** for any operator-facing UI. BEAM processes are the unit of concurrency for workers and per-thread state. OTP supervision trees own the lifecycle and restart semantics of workers, ingestion pipelines, and action runners. Phoenix handles HTTP ingress (webhooks, API), and LiveView handles internal dashboards (event stream, thread state, worker status) without a separate frontend stack.

The load-bearing reason is the **BEAM concurrency model**: per-worker processes with isolated state and supervision map directly onto the architecture in [`docs/06-state-machine.md`](../docs/06-state-machine.md) and the worker runtime described in [`OPERATING_MODEL.md`](../OPERATING_MODEL.md). We are not building an LLM library; we are building a runtime for many small, stateful, fault-tolerant actors. That is what BEAM is for.

## Consequences

- Worker isolation, restart-on-crash, and per-thread state are runtime primitives instead of things we build on top of a job queue. This shortens the wedge — fewer load-bearing pieces to invent.
- One language and one runtime cover ingestion, state, action execution, and UI. The repo stays coherent and the team stays small.
- LiveView removes the need for a separate frontend toolchain for operator surfaces; ops UI can ship in the same PR as the backend change it observes.
- LLM and AI-tooling ecosystems are richer in Python/Node. When we need a library that only exists there, we will call it over HTTP/IPC rather than port it. This is accepted, not regretted.
- Hiring and onboarding favor people willing to learn Elixir. This is accepted; the team is the team.
- Any future ADR that proposes adding a second primary runtime (e.g., a Python service that holds worker state) has to argue against this one.

## Alternatives considered

- **Node/TypeScript + Next.js** — Closest to the LLM tooling ecosystem, but workers would live on top of an external queue and process model instead of as first-class supervised entities. We would spend the wedge rebuilding what OTP gives us.
- **Go + htmx/React** — Excellent concurrency, but no supervision tree, no built-in process isolation per worker, and a separate frontend stack for the operator UI. More moving parts for the same architecture.
- **Python + FastAPI/Celery** — Strongest AI/LLM library coverage, but the worker model leans entirely on external infrastructure (Celery, Redis, a separate state store) to approximate what BEAM provides natively. Wrong shape for a stateful agent runtime.
- **Rust + Axum** — Performance and safety are real, but Guild is an orchestration platform, not a hot path. The cost of Rust ergonomics for a small team building a stateful, evolving system is not justified by the workload.
