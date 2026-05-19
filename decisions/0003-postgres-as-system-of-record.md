# 0003 — Postgres as the single system of record

**Status:** Accepted

## Context

Guild's architecture has several pieces of state to put somewhere durable: the normalized event stream ([`docs/01-event-stream.md`](../docs/01-event-stream.md)), thread linkage ([`docs/02-thread-model.md`](../docs/02-thread-model.md)), per-thread state machines ([`docs/06-state-machine.md`](../docs/06-state-machine.md)), context-assembly caches ([`docs/03-context-assembly.md`](../docs/03-context-assembly.md)), and work-claiming records ([`docs/08-work-claiming.md`](../docs/08-work-claiming.md)). Each could justify a different storage technology if argued in isolation. None of them — at v1 — needs anything Postgres can't do.

The runtime decision ([`0002-elixir-phoenix-liveview.md`](0002-elixir-phoenix-liveview.md)) committed us to Elixir/Phoenix; the home-cloud cluster already runs CNPG. We need to commit to a database before the wedge implementation, so subsequent ADRs (event-table shape, thread linkage queries, state transitions) can be written against a concrete substrate instead of in the abstract.

## Decision

**Postgres is the single system of record for Guild.** Event stream, thread model, worker state, context-assembly cache, and work-claiming records all live in one Postgres database (`guild_app`, provisioned as the CNPG `guild-pg` cluster). When one of those concerns outgrows what Postgres can do well, that pressure becomes the trigger for a follow-up ADR — not a premature split.

The load-bearing reason is the **"dumbest version that lets a Guild worker use it"** principle from [`OPERATING_MODEL.md`](../OPERATING_MODEL.md): self-hosting is the success metric and the design constraint. Five storage technologies that each "fit" one component is not the dumbest version — it is five operational surfaces, five backup stories, five places thread context can be inconsistent. One Postgres is the dumbest thing that gives every subsystem ACID, JSONB for the heterogeneous event envelope, LISTEN/NOTIFY for cheap inter-node pub-sub, and pgvector if context assembly ever grows into embeddings.

## Consequences

- Phoenix/Ecto idioms apply everywhere: migrations are `mix ecto.migrate`, schemas are Ecto schemas, the event store is a table you can `SELECT` from in a console. No bespoke storage layer to learn or maintain.
- Thread linkage and state transitions get transactional guarantees as a free byproduct, not as something the worker runtime has to implement.
- A future ADR that splits a concern out of Postgres (an event log, a separate vector store, a hot-state cache) has to argue against this one and identify the specific Postgres limit it hit.
- The cluster's CNPG operator handles provisioning, failover, and (eventually) backups. No new operational surface added.
- pgvector is installed on the `guild_app` template — available if needed, with no commitment to using it.

## Alternatives considered

- **SQLite** — Single-file, embeds in the pod. Loses concurrent writers across BEAM nodes and gives us no `LISTEN/NOTIFY` channel for inter-node pub-sub. Would force a separate message bus the moment Guild runs on more than one node.
- **Mnesia (BEAM-native)** — Tempting on the "stays inside BEAM" axis, but operationally a footgun: split-brain handling is manual, schema migrations are painful, and the failure modes are unfamiliar to anyone who has not run Mnesia in anger. Workers should not be the team's first encounter with Mnesia drama.
- **ETS/DETS only** — In-memory plus disk, no transactions across processes, no query language for the thread model, no point-in-time recovery. Fine as a process-local cache; nowhere near enough as a system of record.
