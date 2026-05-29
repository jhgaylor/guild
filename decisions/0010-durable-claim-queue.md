# ADR 0010 — Durable Claim Queue

**Status:** Accepted
**Date:** 2026-05-28

## Context

`GuildWeb.WebhookController.receive/2` currently dispatches `Guild.Claiming.claim_issue/2` via `Task.start/1` — a fire-and-forget with no retry, no persistence, and no backpressure. If the process crashes after the webhook returns 200, the claim is lost silently. G4 Slice 2 replaces this with a durable, retryable queue so a webhook handler crash cannot drop a legitimate claim.

Three options were evaluated:

**Option A — Oban (Postgres-backed job queue)**

Oban is a mature, widely-used Elixir job queue that stores jobs in an `oban_jobs` Postgres table, retries on failure with configurable backoff, and provides uniqueness constraints, telemetry, and a web UI (Oban Web, optional). It integrates with Ecto and Repo via a single supervisor entry. The Oban team actively maintains it; the community is large.

Pros:
- Persistent across restarts (Postgres-backed); no job is lost if the VM crashes after enqueue.
- Built-in retry with exponential backoff and max-attempt caps.
- Unique job constraints (by args) prevent duplicate enqueue for the same issue — second layer of defense on top of the advisory lock in `Guild.Claiming`.
- Telemetry hooks and optional Oban Web UI visible to the operator.
- Minimal boilerplate: one `use Oban.Worker` module, one `Oban.insert/1` call in the controller.
- Well-documented upgrade path; the OSS core is MIT licensed.

Cons:
- Adds a dependency (`{:oban, "~> 2.18"}`).
- Requires a schema migration (`oban_jobs` table + indexes, generated via `mix oban.install`).
- Slightly more moving parts than a hand-rolled solution.

**Option B — Broadway (data pipeline / consumer)**

Broadway is designed for high-throughput concurrent data ingestion (Kafka, SQS, RabbitMQ). It provides backpressure and rate control via a producer-consumer topology.

Pros:
- Good for high-volume, high-parallelism workloads.
- Built-in backpressure.

Cons:
- Requires a durable producer (e.g. SQS or a custom Postgres poller) — Broadway itself is not a persistence layer.
- Adds significant complexity for a use case with single-digit events/minute: defining producers, processors, and batchers is over-engineering.
- Does not provide retry-on-failure semantics without additional infrastructure.
- Wrong fit for the problem: Guild's claim rate is low-volume; backpressure is not the bottleneck.

**Option C — Hand-rolled `claim_jobs` Postgres table**

A custom table (`claim_jobs`) with columns `id`, `issue_number`, `repo`, `status`, `attempts`, `last_error`, `inserted_at`, `scheduled_at`. A GenServer polls the table and dispatches workers.

Pros:
- No new dependency.
- Full control over schema and semantics.

Cons:
- Reimplements what Oban already provides correctly: polling interval, retry backoff, uniqueness, telemetry, visibility.
- Likely to have subtle correctness bugs (race between poll and dispatch, missed retries, no exponential backoff) that Oban has already solved.
- Maintenance burden — the team maintains the queue, not just the workers.
- Violates the "dumbest version" principle when Oban already solves this correctly.

## Decision

Use **Oban (Option A)**. The claim rate is low (single-digit events per minute in any foreseeable Guild deployment), so Broadway's backpressure machinery is unnecessary. Hand-rolling a queue would recreate problems Oban has already solved and add ongoing maintenance burden. Oban's Postgres-backed persistence, retry semantics, and uniqueness constraints are exactly what the `Task.start` replacement needs. The dependency cost is justified.

The worker (`Guild.Workers.ClaimWorker`) will:
- Accept `%{"issue_number" => n, "repo" => r}` as args.
- Call `Guild.Claiming.claim_issue/2`.
- Return `{:ok, _}` on success.
- Return `{:cancel, :already_claimed}` if the claim is rejected (advisory lock lost — Oban will not retry a cancelled job).
- Return `{:error, reason}` on transient failures (Oban retries with backoff).

A unique constraint on `(worker, args, queue)` with `replace_args: false` prevents duplicate enqueue for the same issue number.

## Consequences

- `mix.exs` gains `{:oban, "~> 2.18"}`.
- A migration adds the `oban_jobs` table.
- `GuildWeb.Application` gains an Oban supervisor entry.
- `GuildWeb.WebhookController.receive/2` replaces `Task.start(fn -> Guild.Claiming.claim_issue/2 end)` with `Guild.Workers.ClaimWorker.new(%{...}) |> Oban.insert!()`.
- The advisory lock in `Guild.Claiming` is retained as a second-layer guard (a duplicate job that slips through uniqueness still cannot double-dispatch to Fountain).
- Oban Web is NOT added in Slice 2 — operator visibility via ROADMAP / Reconcile logs is sufficient for now.

## Alternatives considered

- **Broadway** — backpressure pipeline built for high-volume consumers; requires its own durable producer and adds significant topology complexity for single-digit-per-minute claim volume. Wrong fit.
- **Hand-rolled `claim_jobs` table** — would recreate Oban's polling, retry, and uniqueness logic with higher maintenance burden and likely subtle correctness bugs. Violates "dumbest version" when Oban already exists and is correct.
