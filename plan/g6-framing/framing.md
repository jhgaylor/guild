# G6 — Framing

Framing for G6 produced at the close of G5. Captain-picard decomposes this
into a slice plan analogous to `plan/g5/slice-plan.md`; the driver reviews and
approves that slice plan before any slice is dispatched.

## Thesis

**Make the signal channels (Slack, Linear) genuinely useful, and tidy the corners.**

G5 made Guild observable and steerable, but the signal channels are still
shallow: Slack is outbound-only + slash commands; Linear is create-on-claim
only; there's no operator digest, no interactive buttons, no inbound webhooks
from Linear. And a handful of small carry-overs accumulated (`updated_at` proxy
for stuck detection, redundant `get_status` re-checks in Pass D, OTP 28.0
perf warning, missing Linear `:executing` transition, sectioned thread view).
G6 deepens the adapter layer into a real ops surface and lands the polish.

Builds on the G4 adapter scaffolding, the G5 Slack control plane, and the
Reconcile passes A–D.

## Item inventory

### 1. Slack interactive buttons (Block Kit actions)
Issue: G4's outbound Slack messages are plain text; G5's control plane requires
the operator to type `/guild hold 34`. A button on the `:pr_open` / `:done`
messages ("Hold this thread", "Abandon") is materially faster and matches how
operators actually use Slack. Fix: send Block Kit blocks with action buttons on
outbound messages; new `POST /slack/interactions` endpoint (same v0 HMAC,
fail-secure) that routes button clicks through `Guild.Control`. **Priority:
high** — biggest UX win in G6, complements the slash command. No ADR (Block Kit
is standard).

### 2. Bidirectional sync — inbound Linear + Slack events
Issue: Guild is currently event-driven on GitHub only. Linear issue updates
(state changes, comments) and Slack channel activity (operator notes, threads
on PR messages) don't flow back into Guild. Fix: inbound webhook from Linear
(issue state, comments) and Slack Events API ingestion (selected messages,
reactions on Guild's outbound messages), mapped to `Event` rows; *selected*
inbound events drive state changes (e.g. a Linear issue closed → log + warn;
Slack 🛑 reaction on a `:pr_open` message → hold the thread). **Priority:
medium-high** — the headline G6 capability. **Needs an ADR** (which inbound
events drive state vs only-record; the security model for the new endpoints;
Slack Events API verification flow).

### 3. Operator digest (Slack)
Issue: the operator gets no proactive summary. Stuck alerts fire individually;
there's no "weekly digest" view. Fix: an Oban-cron job that posts a periodic
Slack summary — shipped/in-flight/stuck/failed counts + links to the worst
offenders. Was a Slice 4 stretch in G5; carry over. **Priority: medium**. No
ADR.

### 4. Linear `:executing → In Progress` transition
Issue: `Guild.Adapters.Linear.state_id(:in_progress)` helper exists but the
`:executing` transition path doesn't call it; created Linear issues sit in
their team's default state forever. Fix: wire it into the `:executing`
transition in `Guild.Claiming` (gated on `linear_issue_id` + the env var being
set, like the `:done` path). **Priority: low**, tiny PR. No ADR.

### 5. Pass D efficiency — artifact terminated flag
Issue: Reconcile Pass D re-calls `Fountain.get_status` on every terminal
thread every 30s forever (one network call per terminal thread per cycle),
even when the conv is already `:terminated`. Fix: add a `terminated` boolean
(or `terminated_at`) on the `fountain_conversation` Artifact; Pass D queries
where this is false; on successful termination (or already-terminated status)
flip it. **Priority: medium** — bounded but real ongoing waste. No ADR.

### 6. Precise stuck detection — `state_entered_at`
Issue: G5 Pass C uses `threads.updated_at` as a proxy for time-in-state, but
`updated_at` bumps on *any* thread write (owner, `linear_issue_id`,
`last_alerted_at`, `held`), under-reporting staleness. Fix: add
`state_entered_at` column updated by `Meta.update_thread_state/2` on every
transition; Pass C queries against it; index badge/banner compute from it.
**Priority: medium**. No ADR (decision deferred from ADR 0014).

### 7. OTP 28.1+ base-image bump
Issue: the prod pod logs "Erlang/OTP 28.0 detected. Regexes will be re-compiled
from source at runtime, which will cause degraded performance." Fix: bump the
Dockerfile base image to one carrying OTP 28.1+ (or downgrade to 27). **Priority:
low**. One-line Dockerfile change + verify clean build.

### 8. Thread-timeline polish *(stretch — may defer to G7)*
Issue: G5 Slice 1 noted the current `/threads/:id` view shows events/decisions/
notes/artifacts as separate sections; the original spec wanted a single
interleaved chronological timeline, plus a `context_snapshot`-nil indicator.
Fix: render the four sources merged into one chronological feed; show a "snapshot
trimmed" marker on retention-nulled decisions. **Priority: low**. UI-only.

## Suggested execution order

1. **G6 slice 1 — polish foundations (items 4, 5, 6, 7).** Linear `:executing`
   wiring, Pass D `terminated` flag, `state_entered_at` column, OTP bump. No
   ADRs. Lands the carry-overs in one focused slice; tightens reliability
   before the new adapter surface goes in.
2. **G6 slice 2 — Slack interactive buttons (item 1) + operator digest
   (item 3).** Action buttons on outbound `:pr_open`/`:done`; new
   `/slack/interactions` endpoint; cron-scheduled digest. No ADRs. The Slack UX
   tier.
3. **G6 slice 3 — bidirectional sync (item 2).** ADR 0016 first: inbound event
   surface, what drives state vs only-record, verification model. Then Linear
   webhook ingestion + Slack Events API ingestion, with the selected
   state-driving mappings.
4. **G6 slice 4 — thread-timeline polish (item 8).** Stretch; may defer to G7
   if the prior slices crowd the gate.

## Closing criteria

**G6 closes** when (a) the operator can run a real thread end-to-end from
Slack alone — clicking buttons on outbound messages, reading the periodic
digest, and seeing relevant Linear/Slack activity reflected back into Guild;
(b) the reliability carry-overs are landed (OTP bump, accurate stuck timing
via `state_entered_at`, no redundant Pass D `get_status` calls, Linear
`:executing` transition wired). Verified live against a real thread through
the Slack channel only.

## Open architectural questions for the slice plan

- **Inbound event surface (item 2):** Linear webhook config + payload subset
  + Slack Events API subscription set + which events drive state changes vs
  just record `Event` rows. (ADR 0016, gate for slice 3.)
- **Slack interactions endpoint (item 1):** same v0 HMAC scheme as
  `/slack/commands`? (Should be — same secret; verify Slack docs.)
- **Digest schedule + content (item 3):** how often (daily, weekly?), where it
  comes from (a new `Guild.Digest` module summarizing thread counts by state),
  trigger via Oban Cron vs a separate periodic Reconcile pass.
- **`terminated` flag location (item 5):** column on `Artifact` (generic) vs a
  field specific to `fountain_conversation` artifacts. Column is cleaner; could
  reuse for future adapter artifacts.
