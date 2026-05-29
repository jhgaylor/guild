# G5 Slice Plan

**Generated:** 2026-05-29
**Source:** plan/g5-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G5 makes Guild observable and steerable — every thread's live state and history visible in the UI, stuck/failed work surfaced proactively, and the ability to intervene from Slack. Builds on the G2.5 operator UI, G4 Slack/Oban work, and the existing `/threads` LiveView surfaces.

**Architectural decisions settled here:**
- **Oban Web vs custom view (item 1):** Use Oban Web (`{:oban_web, "~> 2.10"}`). Drop-in behind existing operator auth; zero implementation cost for queue visibility. A custom Ecto view would duplicate what Oban Web already provides correctly.
- **Stuck detector placement (item 3):** Run detection in the existing `Guild.Reconcile` GenServer (new Pass C) rather than a separate periodic job — keeps all scheduled inspection in one place, consistent with Pass A/B.

---

## Slice 1 — Oban Web + Thread Timeline

**Goal:** Make Guild legible at a glance. Mount the job queue behind operator auth and enrich the thread detail view with full lifecycle history.

### In-scope

- `mix.exs` — add `{:oban_web, "~> 2.10"}`.
- `lib/guild_web/router.ex` — mount `Oban.Web.Router` at `/jobs` inside the `:auth` pipeline. Add `import Oban.Web.Router`.
- `lib/guild_web/live/thread_live/show.ex` (or `thread_live.ex`) — extend detail view to display a chronological timeline interleaving: Events (type, payload summary, timestamp), decisions_log entries (action, params, context_snapshot nil'd indicator), ContextNotes (type, body), Artifacts (PR link, Fountain conv link), state-transition history (derived from Events), current `owner`.
- `lib/guild_web/live/thread_live/index.ex` — add `owner` column to threads index table.
- Tests: LiveView test asserting `/jobs` returns 401 unauthenticated, 200 authenticated. LiveView test asserting `/threads/:id` renders timeline sections.

### Stubbed at this slice

- Oban Web customization / theming.
- Filtering/search in the timeline.
- State-transition history as a dedicated DB column (derive from events).

### ADRs required

None. (Oban Web decision settled above.)

### Acceptance criteria

- `mix test --exclude e2e` green.
- Authenticated `GET /jobs` renders Oban dashboard; unauthenticated → 401.
- `/threads/:id` shows interleaved timeline with events, artifacts, and `owner`.
- No behavior change to claiming, reconcile, or webhooks.

### Depends on

G4 main (PRs #27–#36 merged). Oban already in `mix.exs`.

### Estimate

~170 LOC + tests. One engineer.

---

## Slice 2 — Stuck/Failed Surfacing + `threads.owner` Release

**Goal:** Turn silent stalls into visible ones. Surface stuck threads and exhausted Oban jobs in the UI and via Slack alert. Clear stale `owner` on terminal state.

### In-scope

- ADR `decisions/0014-stuck-threshold-notify-policy.md` — thresholds per state (`:executing` > 2h, `:pr_open` > 48h), detection in Reconcile Pass C, Slack dedup approach (`last_alerted_at`). Must precede implementation.
- `lib/guild/reconcile.ex` — Pass C: query threads whose age-in-state exceeds thresholds; send Slack alert via `Guild.Adapters.Slack.post_message/2` with dedup (skip if alerted within cooldown). Also: clear `owner` (set nil) when a thread enters any terminal state (`:done`, `:failed`, `:abandoned`).
- `lib/guild/schemas/thread.ex` — add `last_alerted_at :utc_datetime` field.
- Migration for `last_alerted_at`.
- `lib/guild_web/live/thread_live/index.ex` — attention badge/indicator for stuck threads (age-in-state > threshold, computed in assigns).
- `lib/guild_web/live/thread_live/show.ex` — stuck warning banner on detail view.
- Tests: Pass C fires alert for over-threshold thread; does not double-alert within cooldown; `owner` nil'd on terminal transition; index shows attention badge.

### Stubbed at this slice

- Per-state thresholds configurable via env/DB (module constants for now).
- Alert escalation / oncall paging.
- Oban dead-letter surfacing in threads UI (visible via Oban Web from Slice 1).

### ADRs required

- `decisions/0014-stuck-threshold-notify-policy.md` — thresholds, detect-in-reconcile rationale, Slack dedup. Must be written and committed before implementation.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Thread in `:executing` > threshold → Slack alert; second reconcile pass within cooldown does not re-alert.
- `owner` nil when thread reaches `:done` / terminal.
- Threads index shows attention badge for stuck threads.

### Depends on

Slice 1 merged.

### Estimate

ADR (~1 page) + ~200 LOC + tests. One engineer.

---

## Slice 3 — Slack Human-in-the-Loop (Inbound Control)

**Goal:** Let the operator steer in-flight threads from Slack. At minimum: `hold`, `resume`, `abandon`. This is the "steerable" headline capability of G5.

### In-scope

- ADR `decisions/0015-inbound-slack-control.md` — (a) inbound surface: slash command vs Events API vs interactive message actions; (b) control vocabulary: `hold` / `resume` / `abandon`; (c) control→state mapping: `hold` sets a thread flag + cancels Oban job; `resume` re-enqueues; `abandon` → `:abandoned` + `owner` nil. Gate implementation on driver approval of this ADR.
- `lib/guild_web/controllers/slack_controller.ex` — new controller receiving inbound Slack requests; verify `X-Slack-Signature` HMAC (fail-secure: reject all if `SLACK_SIGNING_SECRET` absent); parse command/action; call `Guild.Control`.
- `lib/guild/control.ex` — `hold/1`, `resume/1`, `abandon/1` on Thread by id or issue number; interact with Oban as decided in ADR.
- `lib/guild_web/router.ex` — `post "/slack/events"` (or `/slack/commands`) outside `:auth` pipeline; auth is via Slack signature.
- `lib/guild/schemas/thread.ex` — add `:held` to state machine if ADR uses a state flag.
- `k8s/secret.yaml` — add `SLACK_SIGNING_SECRET` (placeholder base64 + operator comment).
- Tests: valid signature + `hold` → thread paused; invalid signature → 403; `abandon` → `:abandoned` + owner nil; `resume` → re-enqueued; missing `SLACK_SIGNING_SECRET` → all inbound rejected.

### Stubbed at this slice

- "Approve before merge" flow (G6).
- Multi-repo slash command routing (defaults to most recent active thread).
- Interactive message action buttons (implement slash command first).

### ADRs required

- `decisions/0015-inbound-slack-control.md` — inbound surface, control vocabulary, control→state mapping. **Implementation gated on ADR approval.**

### Acceptance criteria

- `mix test --exclude e2e` green.
- Valid inbound Slack command → correct thread state change.
- Invalid/missing signature → 401/403, no state change.
- `hold` pauses thread + cancels Oban job; `resume` re-enqueues; `abandon` → `:abandoned` + owner nil.
- `SLACK_SIGNING_SECRET` absent → fail-secure (reject all inbound).

### Depends on

Slice 2 merged. ADR 0015 approved.

### Estimate

ADR (~2 pages) + ~250 LOC + tests. One engineer. ADR approval may add a review round.

---

## Slice 4 — Worker-Conv Lifecycle + Operator Digest *(digest may defer to G6)*

**Goal:** Stop worker convs accumulating silently after their thread finishes. Terminate Fountain convs on terminal thread state. Add a periodic Slack digest (stretch).

### In-scope

- `lib/guild/reconcile.ex` — Pass D: for threads in terminal state with a linked `fountain_conversation` Artifact not yet `:terminated`, call Fountain API to close the conversation; update Artifact status. Idempotent — skip already-terminated convs.
- `lib/guild/adapters/fountain.ex` (or existing HTTP adapter) — add `terminate_conversation/1` wrapping the Fountain termination endpoint; if endpoint unavailable, mark Artifact `:terminated` locally.
- `lib/guild_web/live/thread_live/show.ex` — show worker conv status (running / terminated) in timeline artifact entry.
- *(Stretch — may defer to G6)* `lib/guild/digest.ex` — `send_digest/0` summarizes shipped/in-flight/stuck counts; triggered via `Oban.Cron` entry. Posts via `Guild.Adapters.Slack.post_message/2`.
- Tests: Pass D terminates conv for done thread; does not re-terminate already-terminated conv. Thread detail shows conv status. (Stretch: cron fires, Slack receives digest.)

### Stubbed at this slice

- Operator digest (deferred to G6 if scope tightens).
- Worker conv restart / re-dispatch from the UI (G6).
- Per-worker conv resource usage visibility.

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Thread reaching `:done` → linked Fountain conv terminated within next reconcile cycle.
- No double-termination on subsequent passes.
- Conv status visible in thread detail view.
- *(Stretch)* Scheduled digest posts to Slack.

### Depends on

Slice 3 merged. (Can begin after Slice 2 if Slice 3 is blocked on ADR review.)

### Estimate

~150 LOC (Pass D) + optional ~100 LOC (digest). One engineer.

---

## Slice execution order summary

| Slice | Items covered | ADRs | Can parallelize with |
|-------|--------------|------|----------------------|
| 1 | Oban Web, thread timeline (items 1+2) | — | — |
| 2 | Stuck/failed surfacing, owner release (items 3+5) | 0014 | ADR 0014 can draft during Slice 1 review |
| 3 | Slack inbound control (item 4) | 0015 | — |
| 4 | Worker-conv lifecycle, digest stretch (items 6+7) | — | After Slice 2 if Slice 3 ADR is slow |

Slice 1 gates everything — legibility first. Slice 2 ADR 0014 can be drafted while Slice 1 is in review. Slice 3 ADR 0015 gates the "steerable" milestone. Slice 4 can start after Slice 2 if the Slice 3 ADR review is the bottleneck.

**G5 closes** when the operator can run Guild day-to-day without `kubectl`: full thread timeline in UI, Oban queue visible, stuck threads and jobs flagged proactively (UI + Slack), and `hold`/`abandon` steerable from Slack. Verified live against a real thread.
