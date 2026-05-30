# Guild Demo Runbook

## Try It First

Guild runs entirely on your own infrastructure — no data leaves your environment. The platform deploys to any Kubernetes cluster you control, reads from your GitHub and Slack, and hands work off to a Fountain AI engineer you provision in your own workspace. Before running this demo, follow [docs/setup.md](setup.md) to bring up a fresh Guild instance against a real repository. The walkthrough below runs live and takes about five minutes end-to-end; the deep dive that follows pauses to explain what is happening under the hood at each step.

---

## 5-Minute Demo

Guild is a platform for autonomous workers that participate in the software development lifecycle. Unlike a webhook bot that fires once and forgets, Guild maintains persistent thread state across every event — issue opened, review requested, Slack message received, PR merged — and dispatches a Fountain AI engineer to do the work. The result is a system that picks up `bot-ready` issues, implements them, opens a PR, and closes the loop in Linear and Slack with zero human intervention.

**Step 1 — Open a bot-ready issue.**
On the configured repository, create a new issue and apply the `bot-ready` label. Keep the title and description concrete so the AI engineer has something to implement.

**Step 2 — Watch `/threads`.**
Open the Guild UI at `https://<your-deploy-host>/threads`. Within a few seconds the new thread appears. Refresh and watch the state column move from `:new` → `:claiming` → `:executing`.

**Step 3 — Inspect `/jobs`.**
Open `https://<your-deploy-host>/jobs` (the Oban dashboard). A `ClaimWorker` job appears in the `:claims` queue and quickly moves to processed. This is the moment Guild won the advisory lock and dispatched the Fountain conversation.

**Step 4 — Check Slack.**
In the Guild Slack channel, an interactive message arrives with three Block Kit buttons: **Hold**, **Abandon**, and **View**. Hold pauses execution without discarding state; Abandon terminates the Fountain conversation and releases the thread; View links directly to the GitHub issue.

**Step 5 — Watch the thread reach `:done`.**
When the Fountain engineer opens a PR, the thread transitions to `:pr_open`. When the PR is merged (or closed), the thread moves to `:done`. Linear is updated automatically if `LINEAR_API_KEY` is configured.

**Step 6 — Close.**
"Guild claimed the issue, spawned a Fountain AI engineer, merged the PR, and updated Linear — zero human intervention."

---

## 15-Minute Deep Dive

Run the same five steps but pause at each transition to explain the mechanics.

### After Step 1 — Claiming

The `bot-ready` label triggers a GitHub webhook to `POST /api/webhooks/github`. Guild normalizes this into an event envelope ([Normalized Event Stream](01-event-stream.md)) and creates a thread row ([Thread Model](02-thread-model.md)).

A `ClaimWorker` job is enqueued in the Oban `:claims` queue with unique args keyed on `thread_id` — duplicates are deduplicated by Oban. The job acquires a Postgres advisory lock on the thread, then executes a compare-and-swap: if `threads.owner` is `nil`, it sets it to the current worker and advances state to `:executing`. This is the arbitration mechanism documented in [ADR 0011](../decisions/0011-claiming-arbitration.md). The advisory lock + CAS pattern ensures exactly-once claiming even under concurrent Guild pods.

Source: `lib/guild/workers/claim_worker.ex`.

### After Step 2 — Reconciliation Passes

Guild's reconciler runs on a configurable schedule and processes every active thread through four passes:

- **Pass A (executing → pr_open):** When the Fountain conversation is idle and a matching open PR exists on GitHub, the thread advances to `:pr_open`.
- **Pass B (pr_open → done):** When the merged or closed PR webhook arrives, the thread moves to `:done` and the Fountain conversation is terminated.
- **Pass C (stuck detection):** If a thread has been in `:executing` for longer than the configured threshold with no activity, the reconciler sends a Slack alert ([ADR 0014](../decisions/0014-stuck-threshold-notify-policy.md)).
- **Pass D (terminal cleanup):** For threads in a terminal state (`:done`, `:abandoned`), any open Fountain conversation is terminated to avoid orphaned compute.

### After Step 4 — Slack Control Plane

Guild's Slack integration is not just notification — it is a control plane. The `/guild` slash command accepts directives from operators. The **Hold**, **Abandon**, and **View** Block Kit buttons map to interactive action payloads that hit `POST /slack/interactions`. A `:stop_sign:` reaction on any Guild message also triggers a hold.

Hold sets `threads.held = true`, which is orthogonal to the state machine — a held thread does not advance but retains its current state. Abandon terminates the Fountain conversation and moves the thread to `:abandoned`. All inbound Slack payloads are verified with `SLACK_SIGNING_SECRET` before processing; unauthenticated requests are rejected 403.

See [ADR 0015](../decisions/0015-inbound-slack-control.md) and [ADR 0016](../decisions/0016-bidirectional-sync.md) for the full control-plane design and the bidirectional GitHub ↔ Slack sync that keeps both surfaces in sync.

### After Step 5 — Retention and Summarization

Guild accumulates decision logs and context notes per thread over the lifetime of a conversation. Two mechanisms keep storage bounded:

- **Retention** (`lib/guild/retention.ex`): Keeps the 200 most recent `decisions_log` rows per thread and nulls `context_snapshot` on older rows.
- **Summarization** (`lib/guild/summarization.ex`): When a thread accumulates more than 50 `context_notes`, Guild POSTs the batch to Fountain and replaces them with a single summary note. This keeps context assembly fast without losing signal ([ADR 0009](../decisions/0009-decisions-log-retention.md)).

The `decisions/` folder in this repo follows the same pattern for the platform itself: every significant architectural choice is recorded as a numbered ADR so the autonomous workers that read `OPERATING_MODEL.md` have access to the full reasoning history.
