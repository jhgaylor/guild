# G4 — Framing

Framing for G4 produced at the close of G3, ahead of the next driver session.
Captain-picard (or a fresh customer-researcher) decomposes this into a slice
plan analogous to `plan/g2-wedge-b/slice-plan.md`.

## Thesis

**Make Guild safe and broad enough to run unattended.** G3 proved Guild can
build itself end-to-end on one repo with one worker; G4 hardens the load-bearing
gaps that became real the moment that loop was live (race conditions, auth,
secrets continuity, retry semantics) and widens the surface (more signal
channels, more repos, more workers). After G4 a non-driver human should be able
to point Guild at their own repo without rebuilding it.

## Item inventory

Eight items, surfaced during G2 and G3. Some are bounded fixes; some need ADRs.

### 1. Duplicate-dispatch race (correctness)
Issue: creating a `bot-ready`-labeled issue fires `issues.opened` + `issues.labeled`
near-simultaneously; both webhook handlers pass the "no existing claimed thread"
check and dispatch separate Fountain conversations. Observed live during G3
verification — terminated the duplicate manually.

Fix: serialize the claim decision per anchor. Options: DB-level advisory lock
(`SELECT … FOR UPDATE` on the threads row), GenServer single-flight, or a
unique index on `(anchor_type, anchor_id, state in active states)` partial.
Probably a 30-line PR, no ADR. **Priority: high** (silent double-spend on
Fountain compute).

### 2. Auth on the operator UI
Issue: `/threads`, `/threads/:id`, `/decisions` are world-readable on
`guild.inevitable.fyi`. With the webhook live, the UI also leaks every
GitHub issue Guild interacts with, plus reasoning text + decision params.

Fix: HTTP basic auth via Plug.BasicAuth, credentials from k8s Secret. Or
GitHub OAuth if multi-user later. Start with basic auth — minimal change.
Probably a 30-line PR. **Priority: high** (operational secret-class data
exposed).

### 3. `SECRET_KEY_BASE` from a real Secret
Issue: Dockerfile auto-generates `SECRET_KEY_BASE` per container start via
openssl. Single-replica deploy makes this fine *today*, but any signed cookie
or LiveView session breaks across rollouts.

Fix: add `SECRET_KEY_BASE` to the `guild-app-secrets` Secret (operator
generates once via `mix phx.gen.secret`), drop the openssl fallback in the
Dockerfile entrypoint. ~5-line PR. **Priority: medium** (no signed-cookie
features in use yet, but blocks any).

### 4. Webhook delivery retries
Issue: webhook handler returns 200 the moment HMAC validates and the event
row is inserted, then `Task.start`s the claim. If the in-process Task crashes,
GitHub doesn't retry — the issue is silently un-claimed.

Fix: persist the dispatch intent (an `events` row with a `processed_at` null
column, or a separate `claim_jobs` table) and reconcile periodically. Or use
Oban / Broadway. Probably needs an ADR — pick the durable-job approach. ~80
line PR + ADR. **Priority: medium**.

### 5. `decisions_log` retention
Issue: ADR 0009 set "retain indefinitely" with a TODO. `context_snapshot` will
become the largest rows in the DB once there's real volume.

Fix: rolling delete after N days, or hash-only after N days. Needs an ADR to
update 0009 (decision: pick the policy). ~40-line PR + ADR. **Priority: low**
until volume materializes; comfortably G4 scope.

### 6. Context summarization
Issue: ADR 0007 set bounded recency (last 50 events) with a TODO. Long-running
threads (review cycles, multi-PR work) will overflow.

Fix: cursor + summary rows on `threads`. Needs an ADR update. Moderate effort:
schema change + worker-side prompt updates. ~150-line PR + ADR. **Priority:
low** until a long thread actually happens; could slip to G5 if other items
crowd this slice.

### 7. Linear and Slack adapters
Issue: `Guild.Primitives.Communication.reply_in_thread/2` and
`post_to_channel/2` return `{:error, :permanent, :not_configured}`. `Guild.GitHub`
is the only real adapter. Linear / Slack are in `docs/01-event-stream.md` as
first-class.

Fix: implement both adapters per their docs. Probably 2 separate slices
(Linear adapter + webhook ingestion; Slack adapter + bot identity). Each ~200
LOC + tests. **Priority: medium** — Slack matters for human-in-the-loop
("worker, hold off on this PR"). Linear matters only if the user tracks work
there.

### 8. Multi-worker arbitration + multi-repo
Issue: today there's one `guild-implementer` agent, one `jhgaylor` vault,
one anchor repo. Real Guild needs N workers competing for issues with explicit
claim ownership, and the same Guild instance pointing at multiple repos.

Fix: this is the biggest item by far. Requires:
- A "worker pool" config (multiple agent_ids + vault_ids)
- Work-claiming arbitration (a worker chooses an issue, others see it claimed)
- Per-worker GitHub App credentials
- Anchor → worker routing rules ("this repo's bot-ready issues go to worker X")

Needs at least one ADR (claiming arbitration: optimistic CAS on threads.owner?
Centralized claim leader?). ~400-LOC slice or more, likely splittable. **Priority:
medium-high** — without this, Guild is a one-trick demo.

## Suggested execution order

Driving G4 to closure in a single sweep is unrealistic — the surface is too
heterogeneous. Suggested ordering for the captain-picard slice plan:

1. **G4 slice 1 — race fix + auth + SECRET_KEY_BASE.** Three small fixes
   that make the live system safe to keep running. ~150 LOC total. No ADRs.
2. **G4 slice 2 — webhook retries / durable claim queue.** ADR + ~80 LOC.
3. **G4 slice 3 — retention + summarization** (or split if both are touched).
   ADR 0009 update + ADR 0007 update + schema migration.
4. **G4 slice 4 — Slack adapter.** Most operator-useful of the two
   non-GitHub adapters; gives human-in-the-loop signal channel.
5. **G4 slice 5 — Linear adapter.** Symmetric with Slack; lighter.
6. **G4 slice 6+ — multi-worker + multi-repo.** The biggest design lift; may
   split into 2–3 slices of its own.

**G4 closes** when: a non-driver human can fork the repo, supply their own
GitHub App + Fountain agent + repo URL, and watch their Guild instance claim +
ship a PR autonomously, with the operator UI behind auth and the worker
runtime durable across pod restarts.

## Open architectural questions for the slice plan

- **Durable job queue (item 4):** Oban (Postgres-backed, common in Phoenix
  apps) vs Broadway vs hand-rolled `claim_jobs` table. Pick before slice 2.
- **Claiming arbitration (item 8):** optimistic CAS on `threads.owner` vs
  centralized leader vs queue-pull. Pick before slice 6.
- **Per-worker credentials (item 8):** one Fountain agent per worker (current
  model, replicated) vs one agent + per-conv config switching (would need
  Fountain changes).
- **Multi-repo (item 8):** k8s deployment per repo (simplest, most expensive)
  vs single deployment with per-repo config (cheaper, requires routing
  layer).

These should land as ADRs before their slices.
