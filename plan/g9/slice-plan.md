# G9 Slice Plan

**Generated:** 2026-05-30
**Source:** plan/g9-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G9 closes when the driver, having dry-run a real work thread end to end with Slack live, observes: one Slack thread per work thread (top-level → replies, never scattered top-level messages); replies in the Slack thread show up as Events on `/threads/:id` for that same work thread; `stop_sign` on either parent OR reply holds the work thread; and the "Open in Slack" link on `/threads/:id` lands in the right place.

**Architectural questions settled here (framing open questions resolved):**
- **`slack_thread_ts` + `slack_channel` columns on threads (not reusing artifact URL):** A column is one indexed lookup with no string parsing. The `slack_message` artifact still records each individual posted message for audit; the new columns are the work-thread-level pointer to the conversation root. No breaking change to the artifact pattern.
- **Which messages are top-level vs in-thread:** `:pr_open` posts top-level (the primary "we are working on this" signal, anchors the thread). `:done`, stuck alerts (Pass C), and any future worker narration post as replies (`thread_ts` set). Daily digest (`Guild.Digest`) stays a separate top-level summary — it spans all threads, not one.
- **One Slack App per Guild instance:** Each fork-and-deploy provisions its own App and bot token. The runbook (Slice 3) documents this. No shared-App cross-instance concern.
- **Reply-driven controls (item 7):** Deferred to G10. `stop_sign` reaction covers the common case; slash commands cover explicit control.

**No ADRs required** — all decisions above are settled inline by the framing.

---

## Slice 1 — Outbound Thread Continuity (Items 1, 2)

**Goal:** Make every Slack outbound for a given Guild work thread land in the same Slack thread. The `:pr_open` message is top-level and anchors the thread; `:done` and stuck alerts are replies.

### In-scope

- **Migration** — add `slack_thread_ts :string, null: true` and `slack_channel :string, null: true` to the `threads` table. Index `(slack_channel, slack_thread_ts)` together (needed for inbound lookup in Slice 2). Backfill: for any thread that already has a `slack_message` artifact with a parseable `slack://channel/ts` url, populate `slack_channel` and `slack_thread_ts` from the earliest such artifact (defensive — data set is currently zero, but correct for the upgrade story).
- **Schema** — `lib/guild/schema/thread.ex`: add `field :slack_thread_ts, :string` and `field :slack_channel, :string`.
- **Adapter** — `lib/guild/adapters/slack.ex`: extend `post_message/3` opts to accept `thread_ts:`. When present, include `"thread_ts"` in the `chat.postMessage` payload. Return value is unchanged `{:ok, %{channel: c, ts: ts}}`.
- **Reconcile Pass A** (`:pr_open` transition in `lib/guild/reconcile.ex`): After a successful `post_message`, if `thread.slack_thread_ts` is nil, write `slack_channel` and `slack_thread_ts` from the returned `{channel, ts}` via a targeted `Repo.update`. This is the top-level post — no `thread_ts` in the request.
- **Reconcile Pass B** (`:done` transition): Before calling `post_message`, check if `thread.slack_thread_ts` is set. If yes, pass `thread_ts: thread.slack_thread_ts` so the done message replies under the parent. If nil (no prior Slack post for this thread), post top-level as today.
- **Reconcile Pass C** (stuck alert): Same pattern as Pass B — reply in the work thread's Slack thread if `slack_thread_ts` is set; otherwise post top-level as today.
- Tests: Pass A stores `slack_thread_ts` + `slack_channel` on first post; Pass B passes `thread_ts` when `slack_thread_ts` is set; Pass B falls back to top-level when not set; Pass C similarly; adapter `post_message` with `thread_ts:` includes it in the payload.

### Stubbed at this slice

- Inbound resolution for replies (Slice 2).
- "Open in Slack" UI link (Slice 2).
- Worker progress narration (not yet emitted — future).
- Digest (intentionally separate top-level — no change).

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Migration runs cleanly; `threads.slack_thread_ts` and `threads.slack_channel` columns exist.
- Pass A stores `slack_thread_ts` + `slack_channel` on the first successful outbound post.
- Pass B and Pass C supply `thread_ts` when `slack_thread_ts` is set (verified via mock adapter in tests).

### Depends on

G8 main (already merged). No operator steps — this is pure backend.

### Estimate

~150 LOC (migration + schema + adapter extension + Reconcile wiring + tests).

---

## Slice 2 — Inbound Association + Operator UI Link (Items 3, 4)

**Goal:** Close the round-trip. Replies and reactions on replies in the Slack thread associate back to the correct Guild work thread. The operator can jump from `/threads/:id` to the Slack thread in one click.

### In-scope

- **Inbound resolver** — `lib/guild_web/controllers/slack_controller.ex` events/2 handler. Currently it matches the `slack_message` artifact by exact `channel/ts` to find the work thread. Extend the lookup:
  1. For `reaction_added` events: `item.channel` + `item.ts` (the message the reaction was added to). If `item.ts` is not found in `slack_message` artifacts, fall back to looking up `threads` by `(slack_channel == item.channel AND slack_thread_ts == item.ts)` — handles reactions on the parent. Additionally handle reactions on replies: `item.ts` will be the reply ts (not the parent ts), so also try matching `(slack_channel == item.channel AND slack_thread_ts == item.thread_ts)` where `item.thread_ts` is the reply's parent ts. This covers reactions on both the root message and any reply.
  2. For `message` events (replies in the thread): use `event.thread_ts` (the parent ts of the reply) to look up the work thread via `(slack_channel == event.channel AND slack_thread_ts == event.thread_ts)`. Record the reply as an Event row on the found thread.
  - The `stop_sign` → `Guild.Control.hold` path continues to work as today once the work thread is found via either lookup strategy.
- **"Open in Slack" link** — `lib/guild_web/live/thread_live.html.heex`: when `@thread.slack_thread_ts` is set, render a link just below the info card:
  `https://slack.com/app_redirect?channel=<slack_channel>&message=<slack_thread_ts>`
  (This URL format works for both Slack web and desktop; the simpler `app_redirect` form is more reliable than constructing the team-id URL directly.)
- Tests: reaction_added on parent message (matching by ts) holds the thread; reaction_added on a reply (matching by thread_ts) holds the thread; message event with thread_ts records Event on the correct work thread; "Open in Slack" link renders in thread LiveView when `slack_thread_ts` set; link absent when nil.

### Stubbed at this slice

- Reply-driven text commands ("hold", "abandon" as reply text) — deferred to G10.
- Slack's `thread_broadcast` (also-send-to-channel) option — not needed for v1.

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- `reaction_added` on the parent message or any reply in the Slack thread resolves to the correct work thread.
- `message` events (replies) associate to the correct work thread by `thread_ts`.
- "Open in Slack" link renders on `/threads/:id` when `slack_thread_ts` is set.

### Depends on

Slice 1 merged (`slack_thread_ts` + `slack_channel` columns on threads).

### Estimate

~150 LOC (inbound resolver extension + UI link + tests).

---

## Slice 3 — Operator Slack Setup Runbook (Item 5)

**Goal:** Give the operator everything they need to provision a real Slack workspace and verify the bot can post. Slices 1 and 2 are code-correct; this slice makes them live. **Operator-dependent** — Jake runs the install steps; Guild-side prep is the runbook + sanity-check tool.

### In-scope (Guild-side)

- **`docs/slack-setup.md`** — operator runbook (new file):
  1. Create a Slack App at `api.slack.com/apps` (one App per Guild instance; do not share Apps across forks).
  2. Required **Bot Token Scopes**: `chat:write`, `reactions:read`.
  3. Required **Event Subscriptions** (enable and subscribe to bot events):
     - `message.channels` (replies in public channels the bot is in)
     - `reaction_added` (reactions on any message in channels the bot is in)
     - Request URL: `https://<your-deploy-host>/slack/events`
  4. Install the App to the workspace. Note the Bot OAuth Token (`xoxb-...`).
  5. Add the bot to the target channel (e.g. `#guild`). Note the Channel ID (not the name).
  6. Provision secrets in the live k8s Secret:
     - `SLACK_BOT_TOKEN` — `xoxb-...`
     - `SLACK_CHANNEL_ID` — `C...`
     - `SLACK_SIGNING_SECRET` — from App → Basic Information → Signing Secret
  7. Roll the deployment (`kubectl rollout restart deployment/guild`) so the new env vars are picked up.
  8. Verify: use the sanity-check tool (see below) to confirm the bot can post to the channel.
- **Sanity-check tool** — a release task callable via `bin/guild eval`:
  ```
  Guild.Release.slack_ping()
  ```
  Calls `Guild.Adapters.Slack.post_message("Slack ping from Guild — if you see this, the bot is live.", "")` and prints `:ok` or the error. Operators run this immediately after rolling the new secrets to confirm the wiring before triggering any real work threads.
  Implement in `lib/guild/release.ex` (alongside `migrate/0`, `seed/0`, `add_repo/3`).
- No UI button in `/admin` for the ping (a `bin/guild eval` call is sufficient; the admin integration status card already shows whether the secrets are present).
- Update `docs/setup.md` (existing) with a reference to `docs/slack-setup.md` for the Slack step (one line, no duplication).

### Operator-dependent steps (Jake-only — not automatable by the engineer)

These steps cannot be completed by code and must be done by the driver before Slice 4 closes:

1. **Create a Slack App** for `guild.inevitable.fyi` per `docs/slack-setup.md`.
2. **Install the App** to the workspace and note the Bot Token.
3. **Add the bot to the `#guild` channel** (or equivalent). Note the Channel ID.
4. **Provision `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, `SLACK_SIGNING_SECRET`** in the live Secret and roll the deployment.
5. **Run `Guild.Release.slack_ping()`** via `bin/guild eval` and confirm it returns `:ok` (message visible in Slack).
6. **Wire Event Subscriptions**: in the Slack App settings, enable Events API, set the URL to `https://guild.inevitable.fyi/slack/events`. Verify the URL challenge passes (the handler already responds to `url_verification` events from G6).

### ADRs required

None.

### Acceptance criteria

- **Guild-side (engineering):** `docs/slack-setup.md` committed; `Guild.Release.slack_ping/0` implemented and reachable via `bin/guild eval`; `mix test --exclude e2e` green.
- **Operator-dependent (Jake):** `slack_ping()` returns `:ok` on the live deployment (bot visible in `#guild` channel); Event Subscriptions URL verified in Slack App settings.

### Depends on

Slices 1 and 2 merged (so the runbook describes the fully-wired code path). Can be written in parallel with Slices 1–2; operator steps require the deployment to be rolled with the new secrets.

### Estimate

~50 LOC (`slack_ping/0` in release.ex) + `docs/slack-setup.md` (~400 words). Operator steps: Jake's call.

---

## Slice 4 — Driver Live Dry-Run + Targeted Fixes (Judgment-Gated Close)

**Goal:** With Slack live and both repos configured, run a real work thread end-to-end and verify the G9 promise: one Slack thread per Guild work thread, inbound resolution, "Open in Slack" link. Fix what's cheap; close G9 when the bar is met.

**Prerequisite:** Slice 3 operator steps complete (Slack live, `slack_ping()` `:ok`, Event Subscriptions wired).

### Dry-run checklist (driver executes)

**Outbound threading:**
- Open a `bot-ready` issue on a configured repo.
- Watch Guild claim it and post the `:pr_open` Slack message. Confirm it appears as a **top-level** message in the `#guild` channel.
- Watch `slack_thread_ts` + `slack_channel` populate on the `/threads/:id` page (via "Open in Slack" link appearing).
- Let the thread progress to `:done`. Confirm the `:done` Slack message appears as a **reply** in the same Slack thread (not a new top-level message).

**Inbound association:**
- Reply to the `:pr_open` top-level Slack message (not a slash command — just a reply in the thread). Open `/threads/:id` and confirm an Event row with `source: "slack"` appears for the reply.
- Add a `stop_sign` reaction to the `:pr_open` message. Confirm the thread's `held` flag flips to `true` on `/threads/:id`.
- Add a `stop_sign` reaction to the `:done` reply message. Confirm the same thread hold logic triggers (even though it's already done — the lookup should still resolve; correct behavior is "thread already in terminal state, control is a no-op" rather than a 500).

**Operator UI:**
- "Open in Slack" link on `/threads/:id` — confirm it opens the correct Slack thread in the browser.
- Integration status on `/admin/integrations` — confirm the Slack card shows "✓ ready" (all three secrets present).

**Stuck alert:**
- Optionally: manually trigger a stuck condition (set `state_entered_at` far in the past via eval), confirm Pass C posts the alert as a **reply** in the Slack thread, not a new top-level message.

### What to capture during the dry-run

- Messages that land as wrong level (top-level when they should be replies, or vice versa).
- Inbound events that fail to associate (Event rows missing from the work thread timeline).
- "Open in Slack" link that lands in the wrong place or 404s.
- Any uncaught error in the Slack Events handler (check logs).

### Fix scope

Blocking defects and wince-worthy moments ≤ 1–2 hours each. Defer larger items to G10. Record what was fixed and what was deferred in the ROADMAP G9 Done entry.

### Stubbed at this slice

- Reply-driven text controls (item 7 — G10).
- Slack `thread_broadcast` (replies also visible in channel) — not needed.
- Multi-channel routing (all outbound goes to the one configured `SLACK_CHANNEL_ID`).

### ADRs required

None.

### Acceptance criteria

Driver judgment: "I can watch a work thread from `bot-ready` to `:done` entirely in one Slack thread, reply in Slack and see it on `/threads/:id`, and react with `stop_sign` anywhere in the thread to hold it — without it ever posting a scattered top-level message." Evidenced by dry-run checklist completed and deferred list recorded in ROADMAP.

### Depends on

Slices 1, 2, and 3 merged; Slice 3 operator steps complete.

### Estimate

Dry-run: 1–2 hours. Fixes: judgment-scoped (0–1 day). Close decision: driver.

---

## Slice execution order summary

| Slice | Items covered | ADRs | Notes |
|-------|--------------|------|-------|
| 1 | `slack_thread_ts` column + `post_message` `thread_ts:` + Reconcile wiring (items 1, 2) | — | Foundation; pure backend |
| 2 | Inbound resolver + "Open in Slack" link (items 3, 4) | — | Depends on Slice 1 column |
| 3 | `docs/slack-setup.md` + `slack_ping/0` + operator provisioning (item 5) | — | Can write in parallel with 1–2; operator steps are Jake-gated |
| 4 | Driver live dry-run + targeted fixes | — | Judgment-gated; needs Slice 3 operator steps done |

**G9 closes** when the driver records their go/no-go in the ROADMAP G9 Done entry with dry-run evidence (one Slack thread per work thread, inbound association working, "Open in Slack" link correct).
