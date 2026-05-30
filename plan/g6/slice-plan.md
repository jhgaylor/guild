# G6 Slice Plan

**Generated:** 2026-05-30
**Source:** plan/g6-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G6 matures the signal channels (Slack, Linear) into a real ops surface and lands reliability polish. Eight framing items in four slices, sequenced with foundations first.

**Architectural decisions settled here:**
- **Slack interactions HMAC (item 1):** Same v0 HMAC scheme as `/slack/commands` (same `SLACK_SIGNING_SECRET`; Slack uses the same signing secret for both slash command and interactive component payloads).
- **Digest trigger (item 3):** Oban Cron job (daily, configurable via a module constant). New `Guild.Digest` module summarising thread counts by state; posts via `Guild.Adapters.Slack.post_message/2`.
- **`terminated` flag location (item 5):** New `terminated boolean default false` column on the `artifacts` table (generic — reusable for future adapter artifacts). Pass D queries `where: not a.terminated`; flips it on successful termination or already-terminated status.

---

## Slice 1 — Polish Foundations

**Goal:** Land four reliability/correctness carry-overs in one focused slice before new adapter surface is added.

### In-scope

- **Linear `:executing` transition (item 4):** `lib/guild/claiming.ex` — after `claim_issue/3` transitions thread to `:executing`, call `Guild.Adapters.Linear.update_issue(thread.linear_issue_id, %{state_id: System.get_env("LINEAR_STATE_IN_PROGRESS_ID")})` gated on `thread.linear_issue_id != nil` and env var set. Mirrors the existing `:done` path.
- **Pass D `terminated` flag (item 5):** New migration adding `terminated boolean default false, null: false` to `artifacts` table. `Guild.Schema.Artifact` gains `field :terminated, :boolean, default: false`. `lib/guild/reconcile.ex` Pass D: add `where: not a.terminated` to the query; on successful termination (or already-terminated status from `get_status/1`), `Repo.update!(artifact, %{terminated: true})`. Eliminates redundant per-cycle `get_status` calls for finished convs.
- **`state_entered_at` (item 6):** New migration adding `state_entered_at :utc_datetime, null: true` to threads table. `Guild.Schema.Thread` gains the field. `lib/guild/meta.ex` (or wherever `update_thread_state/2` lives) — set `state_entered_at = DateTime.utc_now()` on every state transition. `lib/guild/reconcile.ex` Pass C — replace `updated_at` proxy with `state_entered_at` for stuck threshold comparison (fall back to `updated_at` if `state_entered_at` is nil, for existing rows). Threads index and detail view: compute stuck badge/banner from `state_entered_at` instead of `updated_at`.
- **OTP base-image bump (item 7):** `Dockerfile` — bump base image to one carrying OTP 28.1+ (e.g. `elixir:1.18-otp-28` or the latest `hexpm/elixir` with OTP >= 28.1). Verify `mix test --exclude e2e` passes with the new image.
- Tests: `claim_issue` wires Linear `:executing` update (Bypass mock); Pass D skips already-terminated artifacts (does not call `get_status` again); Pass C uses `state_entered_at` for threshold comparison.

### Stubbed at this slice

- Per-state `state_entered_at` history (only current state entry tracked).
- Configurable Dockerfile base via env/arg (one-liner bump is sufficient).

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Linear `:executing` update fires on claim (when `linear_issue_id` + env set).
- Pass D does not call `get_status` for artifacts with `terminated: true`.
- Pass C computes stuck age from `state_entered_at`.
- OTP perf warning absent from logs.

### Depends on

G5 main (all slices merged).

### Estimate

~200 LOC + migrations + tests. One engineer.

---

## Slice 2 — Slack Interactive Buttons + Operator Digest

**Goal:** Give outbound Slack messages action buttons and add a daily operator digest — the Slack UX tier.

### In-scope

- **Block Kit buttons (item 1):** `lib/guild/adapters/slack.ex` — update `post_message/2` to accept an optional `blocks:` key; build Block Kit messages with action buttons ("Hold", "Abandon") on `:pr_open` messages and ("View thread") on `:done` messages. Wired from `Guild.Reconcile` transition posts.
- **`/slack/interactions` endpoint:** `lib/guild_web/controllers/slack_controller.ex` — add `interactions/2` action. New route `POST /slack/interactions` outside `:auth` pipeline. Same v0 HMAC verification as `/slack/commands` (same `SLACK_SIGNING_SECRET`, same `CacheBodyReader` raw-body pattern). Parse Slack interactions payload (`payload` form field, JSON-encoded); extract `action_id` and `value` (thread id / issue number); call `Guild.Control.hold/1` or `Guild.Control.abandon/1`. Respond 200 with ephemeral ack.
- **Operator digest (item 3):** `lib/guild/digest.ex` — `Guild.Digest.send_digest/0`: queries thread counts by state (done, executing, pr_open, abandoned, held); formats a Slack message summarizing shipped/in-flight/stuck/failed with links to the worst offenders (most-stuck threads); posts via `Guild.Adapters.Slack.post_message/2`. Triggered by an Oban Cron entry (daily at 09:00 UTC, module constant). Graceful no-op if Slack unconfigured.
- `lib/guild/application.ex` or Oban config — add cron schedule entry for `Guild.Digest`.
- Tests: valid interactions payload + "hold" action -> `thread.held true`; invalid signature -> 403; digest posts correct state counts to Slack (Bypass mock).

### Stubbed at this slice

- Rich digest formatting (links to individual threads beyond the top offenders).
- Reaction-based controls (Slack stop sign -> hold — that is item 2, Slice 3).
- Button on messages older than the action_block `action_id` expiry (Slack handles this gracefully).

### ADRs required

None. (Same v0 HMAC settled above; digest schedule is a constant.)

### Acceptance criteria

- `mix test --exclude e2e` green.
- `:pr_open` Slack message carries "Hold" and "Abandon" buttons; clicking routes through `Guild.Control`.
- Invalid interactions signature -> 403.
- Daily Oban Cron job fires `Guild.Digest.send_digest/0`; Slack receives state summary.

### Depends on

Slice 1 merged.

### Estimate

~250 LOC + tests. One engineer.

---

## Slice 3 — Bidirectional Sync (item 2)

**Goal:** Inbound Linear and Slack events flow back into Guild — selected events drive state changes; all inbound events record an `Event` row.

### In-scope

- **ADR 0016 — inbound event surface:** decide (a) which Linear webhook events to subscribe to and which drive state vs only-record; (b) which Slack Events API events to subscribe to and which drive state (e.g. stop-sign reaction on a Guild `:pr_open` message -> `hold`); (c) verification model for both (Linear: `X-Linear-Signature` HMAC; Slack Events: same v0 scheme). Must precede implementation.
- **Linear inbound webhook:** `lib/guild_web/controllers/linear_controller.ex` — new controller; `POST /linear/webhooks` outside `:auth`; verify `X-Linear-Signature`; parse event type (IssueUpdate, Comment, etc.); insert `Event` row; for mapped state-driving events (per ADR 0016 decision), call appropriate handler.
- **Slack Events API:** `lib/guild_web/controllers/slack_controller.ex` — add `events/2` action; `POST /slack/events` outside `:auth`; v0 HMAC; handle Slack URL verification challenge; parse event type; insert `Event` row; for mapped events (e.g. reaction_added stop-sign on a Guild message -> `Guild.Control.hold/1`) call handler.
- Both endpoints insert `Event` rows (existing `Guild.Schema.Event` table) with appropriate `event_type` and `payload`.
- `k8s/secret.yaml` — add `LINEAR_WEBHOOK_SECRET` (placeholder + operator comment).
- Tests: Linear webhook verified + IssueUpdate inserted as Event; Slack reaction_added mapped to hold; invalid signatures -> 403; Slack URL verification challenge handled.

### Stubbed at this slice

- Full Linear event vocabulary (start with IssueUpdate + Comment).
- Slack message-level threading (react -> hold is sufficient for G6).
- UI display of inbound Linear/Slack events in the thread timeline (visible as generic Events).

### ADRs required

- `decisions/0016-bidirectional-sync.md` — inbound event surface, state-driving mappings, verification model. **Gate: ADR must be approved before implementation begins.**

### Acceptance criteria

- `mix test --exclude e2e` green.
- Linear webhook with valid signature -> `Event` row inserted; invalid signature -> 403.
- Slack `reaction_added` stop-sign on a Guild message -> `Guild.Control.hold/1` called.
- Slack Events API URL verification challenge handled correctly.
- `LINEAR_WEBHOOK_SECRET` in `k8s/secret.yaml`.

### Depends on

Slice 2 merged. ADR 0016 approved.

### Estimate

ADR (~2 pages) + ~300 LOC + tests. One engineer. ADR review round expected.

---

## Slice 4 — Thread-Timeline Polish *(may defer to G7)*

**Goal:** Merge the four timeline sources into one true chronological feed with a context-snapshot-nil indicator.

### In-scope

- `lib/guild_web/live/thread_live.ex` — load all four sources (Events, decisions_log, ContextNotes, Artifacts), merge into a single list sorted by `inserted_at` / timestamp, assign to socket.
- `lib/guild_web/live/thread_live.html.heex` — render the merged feed as one chronological timeline. Add a "snapshot trimmed" visual marker on decisions_log entries where `context_snapshot` is nil (set by `Guild.Retention` in G4 Slice 3).
- Tests: LiveView test asserting the merged timeline renders entries from all four sources in chronological order.

### Stubbed at this slice

- Pagination / virtual scrolling for long threads.
- Filtering by source type.

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- `/threads/:id` renders a single merged chronological timeline.
- decisions_log entries with `context_snapshot: nil` show a "snapshot trimmed" marker.

### Depends on

Slice 3 merged. **May defer to G7** if Slices 1-3 crowd the gate.

### Estimate

~150 LOC + tests. One engineer. UI-only.

---

## Slice execution order summary

| Slice | Items covered | ADRs | Can parallelize with |
|-------|--------------|------|----------------------|
| 1 | Linear :executing, Pass D terminated flag, state_entered_at, OTP bump (4,5,6,7) | — | — |
| 2 | Slack interactive buttons, operator digest (1,3) | — | — |
| 3 | Bidirectional sync (2) | 0016 | ADR 0016 can draft during Slice 2 review |
| 4 | Thread-timeline polish (8) | — | After Slice 3; may defer G7 |

Slice 1 tightens reliability before new surface. Slice 2 completes the Slack UX tier. ADR 0016 can be drafted while Slice 2 is in review. Slice 4 is UI-only and can slip to G7 without blocking G6 close.

**G6 closes** when the operator can run a real thread end-to-end from Slack alone — clicking buttons on outbound messages, reading the daily digest, and seeing Linear/Slack activity reflected back — plus the reliability carry-overs landed. Verified live against a real thread through the Slack channel only.
