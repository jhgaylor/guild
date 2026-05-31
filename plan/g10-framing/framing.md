# G10 — Framing

Framing for G10 produced at the close of G9. Captain-picard decomposes
this into a slice plan; the driver reviews and approves before any
slice is dispatched.

## Thesis

**Guild listens in Slack and acts like a colleague.**

Today Slack is a one-way speaker: Guild posts about work it already
knows about (G9). It does not read general channel traffic and has no
awareness of the conversations happening around it. If someone says in
Slack "hey, can you fix that typo?" Guild ignores it. If someone says
in a new top-level message "did the typo PR ship?" the asker has to
manually find the original Slack thread to continue the conversation
about that work — Guild won't notice the reference.

A colleague behaves differently. A colleague:

- Reads every message in their channels.
- Notices when someone is talking about ongoing work and routes the
  conversation back to where the work lives.
- Notices when someone is making a request and either does it or
  acknowledges it.
- Says nothing when the message is unrelated chatter.

G10 makes Guild behave like that colleague — selectively, with
LLM-driven judgment, on top of the G9 Slack thread infrastructure.

This is a step-change in autonomy. Where G4–G9 added mechanical wiring
(claim queues, durable jobs, state machines, thread mapping), G10
introduces *semantic* engagement — Guild reads messages it was not
explicitly told to act on and decides whether and how to engage.

## Item inventory

### 1. `slack_channels` config table *(routing foundation)*
Issue: when Guild decides "this is new work" from a Slack message, it
needs to know which GitHub repo to open the issue on. Today the only
config surface is `SLACK_CHANNEL_ID` (one channel, one bot identity).
Fix: add a `slack_channels` table with `(channel_id PK, default_repo
FK→repos.full_name, enabled boolean, notes text)`. Operator manages it
via `/admin/slack-channels` (CRUD modeled on the G8 `/admin/repos`
page). Without this Guild has no idea where to file a Slack-derived
issue. **Priority: highest** — gates all new-work materialization.

### 2. Listen in all bot-member channels *(listening foundation)*
Issue: the Events handler today is keyed off message-level dispatching
without channel allow-listing. The bot's Slack-membership IS the
natural allow-list (Slack only delivers events from channels the bot is
in), but the controller doesn't gate on the `slack_channels` table.
Fix: when an inbound `slack.message` event arrives, check that the
channel is in `slack_channels` and enabled. If not, record the Event
(for audit) but don't classify. **Priority: highest** — paired with
item 1.

### 3. `Guild.SlackInbox.classify/1` *(the colleague's brain)*
Issue: the core capability. Given a top-level Slack message, decide
`:new_work | :refers_to_existing | :noise`, with a confidence score and
LLM reasoning. Implementation: a `Guild.Workers.SlackInboxWorker` Oban
job (own queue, args-unique by event id) spawns a short-lived Fountain
conv with a tight classifier prompt. The webhook handler enqueues the
job and returns 200 immediately — the classifier runs async (5–15s
latency is acceptable; this is "colleague responds when they get to
it"). Cheap prefilter before enqueuing: skip bot messages, messages
< 10 chars, messages from the bot's own user id. **Priority: highest**
— the rest of G10 is plumbing around this.

### 4. Reference resolution against open work threads *(the colleague's memory)*
Issue: when classifier says `:refers_to_existing`, it must also identify
*which* work thread. Fix: include the candidate list in the classifier
prompt — the 20 most-recently-updated open work threads (state
`:executing`, `:pr_open`, `:noticed`, `:claimed`; exclude terminal),
each rendered as `{thread_id, anchor (repo#issue), one-line summary
from context_notes/anchor, state, age}`. The classifier returns the
matched thread id (or null). No vector store dependency yet — list-based
prompt is enough for tens of open threads. **Priority: high** — needed
to make `:refers_to_existing` actionable.

### 5. New-work materialization *(create work from messages)*
Issue: when classifier says `:new_work` and the originating channel has
a `default_repo`, Guild opens a GitHub issue. Fix: title from the
message's first line (truncated to 80 chars); body from the full
message + attribution (`> @user in #channel on 2026-05-30T...`); apply
the `bot-ready` label. Same downstream pipeline as today: webhook →
claim → worker → PR. The originating Slack message becomes the first
`Event` row on the newly-created work thread. The bot posts a
confirmation reply to the originating Slack message: "Filed as
[repo#N](link). I'll keep you posted in this thread." **Priority: high.**

### 6. Reference action — pull conversation back to the work thread *(the painful UX you called out)*
Issue: when classifier says `:refers_to_existing` with confidence above
threshold, Guild should pull the conversation back to the work thread.
Fix: (a) record the new Slack message as an `Event` on the existing
work thread (associated via `thread_id`); (b) post a reply to the *new*
Slack message: "@user — this looks like ongoing work: [Open in Slack:
parent thread]. Continuing there." The reply uses the G9 `slack.com/
app_redirect` link format. Confidence below threshold → record the
Event silently, no reply (operator can review on `/admin/slack-inbox`).
**Priority: high** — this is the specific UX Jake called out.

### 7. `/admin/slack-inbox` operator review surface *(trust + override)*
Issue: implicit classification is high-leverage but high-risk. Operator
needs visibility into what Guild is deciding. Fix: a new admin page
listing recent classifications: `{message excerpt, channel, user,
classification, confidence, reasoning, action taken, override
controls}`. Override buttons: "Reclassify as new_work" / "Reclassify as
refers_to existing [pick thread]" / "Reclassify as noise". Override
spawns the action that should have happened. **Priority: medium-high**
— without this G10 is impossible to operate safely.

### 8. Dry-run mode *(de-risk the rollout)*
Issue: turning on an LLM-driven listener in a real channel is a
material trust event. Fix: a `SLACK_INBOX_DRY_RUN` env flag (default
`true` for a deploy or two). In dry-run mode the classifier still
runs and the Event row is recorded with the reasoning, but no
side-effects fire (no GitHub issue, no Slack reply). The operator
reviews `/admin/slack-inbox` for a few days, sees the classifier
matches their judgment, then flips the flag off. **Priority:
medium-high** — the safe way to ship item 3 to a real workspace.

### 9. Self-loop protection *(don't classify Guild's own posts)*
Issue: when Guild posts a `:done` reply or a reference-resolution
reply, that's a new Slack message. We can't classify Guild's own
output — infinite loop risk + nonsense reasoning. Fix: filter at the
prefilter stage on `user_id == bot user id` AND on `subtype ==
bot_message`. Belt-and-suspenders because both signals are usually
present but Slack's behavior here varies by app config. **Priority:
medium** — defensive, but mandatory for any safe rollout.

### 10. *(Stretch — may defer to G11)* Operator reactions as escalation/suppression
Issue: even with implicit classification, operators may want to force
behavior on individual messages. Fix: `:robot:` reaction forces
reclassification (re-run the worker on demand); `:no_entry_sign:`
reaction marks a message as ignored (suppress future classifications +
withdraw any reply already posted). Lower priority — initial G10 ships
without this; operator review surface (item 7) provides the same
escape hatch via the admin UI. **Priority: low.**

## Suggested execution order

1. **G10 slice 1 — routing + listening foundation (items 1, 2).**
   `slack_channels` table + `/admin/slack-channels` CRUD + listening
   gated on enabled channels. No classifier yet; just plumbing. Lands
   the config surface so item 3 has somewhere to write to.
2. **G10 slice 2 — classifier with dry-run only (items 3, 4, 8, 9).**
   `Guild.SlackInbox.classify/1` + Fountain classifier prompt +
   `SlackInboxWorker` Oban job + dry-run mode default-on +
   self-loop guard. End of slice: every top-level message in an
   enabled channel produces a classification Event with reasoning,
   nothing acts on it yet.
3. **G10 slice 3 — new-work + reference actions (items 5, 6).**
   When dry-run flag is OFF: `:new_work` opens a GitHub issue + posts
   confirmation; `:refers_to_existing` posts the reference reply +
   records the Event on the existing thread. Cannot ship without item
   1 (routing) and item 3 (classifier).
4. **G10 slice 4 — operator review surface (item 7).** The
   `/admin/slack-inbox` page + override actions. Can run in parallel
   with slice 3 once slice 2 is merged.
5. **G10 slice 5 — driver live dry-run + targeted fixes.** With the
   classifier off-dry-run in the production workspace, the driver
   posts a new-work request, a reference question, and noise; watches
   the classifier match human judgment; corrects via the admin override
   surface; closes when the colleague behavior feels right.

Slice 1 and 2 must run sequentially. Slice 4 can run in parallel with
slice 3. Slice 5 (the live dry-run) needs everything.

## Closing criterion

**G10 closes** when the driver, having dry-run a live workspace
session, observes:

- A top-level Slack message that describes a new task in an enabled
  channel is converted to a `bot-ready` GitHub issue on the channel's
  default repo. The worker pipeline runs (claim → PR → done). The
  originating Slack message is the first Event on the new work thread.
  The bot posts a confirmation reply to the originating Slack message.
- A top-level Slack message that references existing work (e.g. "did
  that typo PR ship?") gets a reply pointing to the existing work
  thread's Slack thread, and the new message appears as an Event on
  the existing work thread on `/threads/:id`.
- An unrelated noise message produces a `:noise` classification Event
  with reasoning, no GitHub issue, no Slack reply.
- The bot does not classify or act on its own messages (no
  self-loops).
- `/admin/slack-inbox` renders the recent classification stream with
  reasoning visible; override actions work.
- Recorded in the ROADMAP G10 entry with dry-run evidence.

## Open architectural questions for the slice plan

- **Classifier prompt design.** What inputs go into the prompt? At
  minimum: the message text, the channel name, the user's display name,
  the configured `default_repo` for that channel, the candidate list
  of 20 recent open threads. Possibly: recent channel context (last
  N messages) for ambiguous cases. Captain-picard should propose the
  exact prompt shape in the slice plan; we may need an ADR for "what
  counts as work" semantics.
- **Confidence threshold.** What confidence above which we act, below
  which we record-only? Sensible default: 0.7. Tunable per-channel?
  For G10 start with one global default.
- **Fountain conv per classification — wasteful?** Each classification
  spawns + terminates a short-lived conv. Cost is bounded (cheap model,
  short context) but architecturally heavy. Should we instead use a
  direct LLM API call from inside `SlackInboxWorker`? Trade-off:
  consistency (everything goes through Fountain) vs latency/cost. For
  G10 propose Fountain to keep architecture uniform; revisit if it
  becomes the dominant cost driver.
- **Multi-channel outbound.** G9 outbound used `SLACK_CHANNEL_ID` env.
  For G10's `:new_work` confirmation reply and `:refers_to_existing`
  reply, we need to post in the *originating* channel, not the env
  default. `Guild.Adapters.Slack.post_message/3` should take a
  `channel:` option (already does in the underlying API call — just
  not exposed in the public interface). Verify or extend.
- **Reactions as override surface (item 10):** out for G10 unless
  trivial; the admin override page (item 7) covers the operator's
  needs.
- **Rate limit per user/channel.** If someone spams the channel, we
  don't want 50 classifier runs. Propose: 1 classification per (user,
  channel, minute) max. Reasonable default; tunable later.

## Risk register

- **False positive new-work creation.** Classifier files a GitHub issue
  on something that wasn't actually a request. Mitigation: dry-run
  mode (item 8) for initial rollout; admin override (item 7) to close
  the issue + reclassify as noise; soft-delete the issue via `gh issue
  close` from the override action.
- **False positive reference resolution.** Bot posts "this looks like
  ongoing work [X]" but the asker wasn't talking about X. Mitigation:
  confidence threshold; below threshold record-only; reply text is
  hedged ("looks like" not "this is").
- **LLM cost.** ~$0.01–0.05 per classification on a cheap model; at
  100 msgs/day with prefilter dropping half, ~$15–75/mo per active
  channel. Acceptable for a single-team instance, less so for a
  busy multi-channel deployment. Captain-picard's slice plan should
  call this out + propose a cost-cap mechanism if needed.
- **Trust event.** This is the biggest step toward Guild being
  perceived as autonomous. Item 8 (dry-run) is mandatory; the driver
  walks dry-run before flipping the flag.
