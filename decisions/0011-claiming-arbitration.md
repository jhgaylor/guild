# 0011 — Claiming Arbitration

**Status:** Accepted

## Context

Guild can run multiple worker processes simultaneously — across restarts, scaled replicas, or future horizontal deployments. When a new GitHub event arrives and triggers thread creation or state transition, more than one worker may attempt to claim the same thread concurrently. Without arbitration, two workers could each read an unclaimed thread, both decide to claim it, and both dispatch separate Fountain conversations for the same issue.

The existing [`0010-durable-claim-queue.md`](0010-durable-claim-queue.md) establishes that Oban serializes the enqueue step: only one job per thread enters the claim queue at a time. However, serializing the job does not prevent a scenario where the worker crashes mid-claim and a second worker picks up the retry, or where a future configuration runs multiple Oban queues. A second layer of arbitration at the database level is needed to make ownership durable and observable.

Postgres advisory locks (Slice 1) already prevent concurrent execution inside a single node. What is missing is a persistent ownership field on the thread row so that any worker — on any node, at any time — can determine at a glance whether a thread is already being handled.

## Decision

Thread ownership is arbitrated using **advisory locks (existing) combined with an optimistic compare-and-swap (CAS) on a new `threads.owner` column** (nullable string).

The `ClaimWorker` transaction proceeds as follows:

1. Acquire the Postgres advisory lock for the thread (existing behaviour, unchanged).
2. Inside the same transaction, attempt to set `owner = worker_id` with the condition `WHERE owner IS NULL`.
3. If the update affects one row, the claim succeeds and execution continues.
4. If the update affects zero rows (`owner` was already set by another worker), the claim returns `{:cancel, :already_claimed}` and the Oban job is discarded without retry.

The `owner` column stores an opaque string identifier supplied by each worker process (for example, a node name and PID, or a configured worker label). It is set on claim and cleared (set to `NULL`) only when the thread reaches a terminal state or is explicitly released.

## Alternatives Considered

- **Centralized leader election** — A single elected node could be the only one allowed to claim threads. This eliminates races but introduces extra infrastructure (e.g., a distributed lock service or a leader-election library) and a single point of failure. The CAS approach achieves the same safety guarantee using only what Postgres already provides.

- **Queue-pull model (Oban as sole arbiter)** — Relying entirely on Oban's unique job constraint to prevent duplicate claims. Oban does serialize enqueue, but it cannot prevent a retry from racing with a delayed in-flight execution. The persistent `owner` column closes that gap without replacing Oban's role.

- **Pessimistic row locking (`SELECT … FOR UPDATE`)** — Would block concurrent readers for the duration of the transaction. The advisory lock plus CAS approach is non-blocking for readers and keeps the lock scope narrow.

## Consequences

- **`threads.owner` column is added this slice.** A migration adds a nullable `owner` string column to the `threads` table. The `Guild.Schema.Thread` Ecto schema and changeset are updated to include the field. (The column already exists in the schema definition — the migration makes it official in the database schema lineage for deployments that pre-date this slice.)
- **`ClaimWorker` gains a CAS check.** The claiming transaction is updated to perform the conditional update and return `{:cancel, :already_claimed}` on contention. This is a safe, non-breaking change: in a single-worker deployment the `owner IS NULL` condition is always true on first claim.
- **Observability improves.** The `owner` field makes it trivial to query which worker is handling which thread, useful for debugging and future admin tooling.
- **Release semantics are deferred.** How and when `owner` is cleared (on terminal state, on worker restart, on manual override) is a follow-up concern. For this slice, `owner` is set on claim and not programmatically cleared, which is safe because terminal threads are not re-claimed.
