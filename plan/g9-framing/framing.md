# G9 — Framing

Framing for G9 produced at the close of G8. Captain-picard decomposes this
into a slice plan; the driver reviews and approves before any slice is
dispatched.

## Thesis

**One Slack thread per Guild work thread — and exercise it live.**

Today Slack outbound is scattered: `:pr_open` posts a top-level channel
message, `:done` posts a separate top-level message, stuck alerts post
another, the daily digest is another. The operator cannot follow "what is
happening with this work thread" in Slack as one conversation. Inbound is
partly wired (`stop_sign` on a Guild-posted message → hold, via the
`slack_message` artifact) but only resolves for the parent — replies and
reactions on replies don't associate. G9 makes the mapping clean:

- Each Guild work thread gets exactly one Slack thread.
- The first outbound for a work thread is top-level; everything after is a
  reply in that thread (`thread_ts` set).
- Inbound replies and reactions resolve back to the same work thread
  whether they target the parent or a reply.
- The operator UI surfaces the Slack thread link on `/threads/:id` so the
  operator can jump straight to the live discussion.
- And — for the first time since G5 — Slack goes from "code-correct and
  fail-secure" to actually live against a real Slack workspace.

## Item inventory

### 1. `slack_thread_ts` on the Guild work thread *(outbound foundation)*
Issue: there's nowhere to persist "this Slack channel + ts is THIS work
thread's conversation root." Today every outbound post creates a separate
`slack_message` artifact but nothing marks "this one is the parent." Fix:
add `slack_thread_ts :string, null: true` and `slack_channel :string,
null: true` to `threads`. On the first successful outbound post for a
work thread, store both. Subsequent outbound posts for the same work
thread use them as `thread_ts` so Slack threads the message under the
parent. **Priority: highest** — every other G9 item depends on this.

### 2. `post_message/2` accepts `thread_ts:` *(outbound continuity)*
Issue: `Guild.Adapters.Slack.post_message/2-3` currently doesn't expose
`thread_ts`. Fix: extend the opts to accept `thread_ts:` and pass it
through to `chat.postMessage`. Update Reconcile Pass A (`:pr_open`)
to record the new thread when posting, Pass B (`:done`) to reply in it,
Pass C (stuck alerts) to reply in it, and the `reply_in_thread` primitive
to actually use it. **Priority: high.**

### 3. Inbound association — replies + reactions on replies *(inbound continuity)*
Issue: Slack Events handler matches the `slack_message` artifact by exact
`channel/ts`. A reply in the thread has its own `ts` (≠ parent ts) so it
doesn't match. Same for `reaction_added` on a reply. Fix: when handling
`reaction_added` or `message`, look up `(channel, item.thread_ts || ts)`
against the work thread's `slack_thread_ts` (set in item 1) — this
resolves replies AND reactions on replies back to the work thread.
**Priority: high.**

### 4. Slack thread link in operator UI *(use)*
Issue: `/threads/:id` doesn't surface the live Slack conversation. Fix:
when `slack_thread_ts` is set on the thread, render a "Open in Slack"
link using `https://app.slack.com/client/{team_id}/{channel}/thread/{ts}`
or `slack://channel?team={team}&id={channel}&message={ts}` (pick what's
most reliable across Slack web + desktop). **Priority: medium-high** —
this is the visible payoff of items 1–3.

### 5. Operator-pending: provision a real Slack workspace *(make Slack live)*
Issue: Slack has been code-correct + fail-secure since G5 but never
exercised against a real workspace. To dry-run G9, that ends here. Jake
creates a Slack app (or reuses one), adds an `incoming-webhook` and
`chat:write` for outbound, an `Event Subscriptions` for inbound (URL
`https://guild.inevitable.fyi/slack/events`), provisions
`SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, `SLACK_SIGNING_SECRET` in the live
Secret, and adds the bot to the channel. **Priority: gating** — slice 4
dry-run cannot complete without it. Documented as a runbook (`docs/slack-setup.md`).

### 6. Backfill existing threads *(optional polish)*
Issue: threads that already have `slack_message` artifacts (currently:
zero, because Slack has never been live, but the question matters for the
upgrade story when someone forks Guild) would have no `slack_thread_ts`.
Fix: on the migration that adds the column, backfill from the earliest
`slack_message` artifact per thread. Trivial because the data set is
small. **Priority: low** — defensive.

### 7. *(Stretch — may defer to G10)* Reply-thread driven controls
Issue: G5's `/guild hold <issue#>` is a slash command. With proper
thread association, a reply IN the Slack thread containing "hold" or
"abandon" could control the work thread without specifying the issue
number. Fix: parse selected commands from reply messages in known Slack
threads. **Priority: low** — `stop_sign` reaction covers the common case.

## Suggested execution order

1. **G9 slice 1 — outbound thread continuity (items 1, 2).** Schema
   change + adapter extension + Reconcile wiring. The foundation.
2. **G9 slice 2 — inbound association + operator UI link (items 3, 4).**
   The inbound resolver lookup + the `/threads/:id` "Open in Slack" link.
   Closes the round-trip in the UI.
3. **G9 slice 3 — operator-pending Slack setup runbook (item 5).**
   `docs/slack-setup.md` + the secrets list + a sanity-check command to
   verify the bot can post. Jake runs the install.
4. **G9 slice 4 — driver live dry-run + targeted fixes.** With Slack
   live, create a `bot-ready` issue on either configured repo and watch:
   `:pr_open` posts top-level → `:done` lands as a reply → operator
   replies in the thread → reply appears as an Event row associated to
   the work thread → `stop_sign` reaction on the reply also holds.
   Judgment-gated close.

Slices 1 and 2 can run sequentially. Slice 3 (a doc + the operator
action) can land in parallel with 1/2. Slice 4 needs all three plus Jake.

## Closing criterion

**G9 closes** when the driver, having dry-run a real work thread end to
end with Slack live, observes: one Slack thread per work thread
(top-level + replies, never scattered top-level messages); replies in the
Slack thread show up as Events on `/threads/:id` for that same work
thread; `stop_sign` reaction on either parent OR reply holds the work
thread; and the "Open in Slack" link on `/threads/:id` lands in the
right place. Recorded in the ROADMAP G9 entry with dry-run evidence.

## Open architectural questions for the slice plan

- **`slack_thread_ts` + `slack_channel` on threads vs reusing the
  `slack_message` artifact's `url`:** Column is simpler — one indexed
  lookup, no string parsing. The artifact still records each posted
  message for audit; the column is the work-thread-level pointer. Recommend
  the column.
- **Which messages are top-level vs in-thread?** Slice 1 should decide:
  recommend `:pr_open` is top-level (the primary "we are working on
  this" signal); `:done`, stuck alerts, and worker progress narration
  are replies. Daily digest stays separate top-level (it's a summary,
  not a per-thread update).
- **Slice-3 Slack app config:** can we use the same App across multiple
  Guild instances, or one App per instance? Likely one App per instance
  for clean credential isolation. The runbook should note this.
- **Reply-driven controls (item 7):** out for G9. Slash commands +
  reaction-as-control cover the common case.
