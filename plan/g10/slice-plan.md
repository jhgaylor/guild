# G10 Slice Plan

**Generated:** 2026-05-31
**Source:** plan/g10-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G10 closes when the driver, having dry-run a live workspace session, observes: top-level Slack requests become `bot-ready` GitHub issues; references to existing work get a reply pointing back to the Slack thread + appear as Events on `/threads/:id`; noise is silently classified; Guild never classifies its own messages; `/admin/slack-inbox` renders the reasoning stream with working override actions. Recorded in ROADMAP G10 Done with dry-run evidence.

**Architectural decisions (all settled in ADR 0017):**
- OpenRouter direct for stateless one-shot classification; Fountain reserved for stateful multi-turn agent work.
- Default model: `openai/gpt-4o-mini` via OpenRouter; swappable via `OPENROUTER_CLASSIFIER_MODEL`.
- Structured JSON output: `{verdict, confidence, reasoning, matched_thread_id}`. `slack_inbox_events` stores this as `thread_id` (dual-purpose: classifier match for `:refers_to_existing`; backfilled by thread-creation path for `:new_work`).
- Confidence threshold: 0.7 global default, env-configurable.
- Rate limit: 1 classification per (user_id, channel_id) per 60s, enforced via DB query on `slack_inbox_events`.
- Failure modes: timeout/unreachable → 1 retry, then record-and-skip; malformed JSON → treat as `:noise`; no API key → inbox disabled.
- Dry-run mode: `SLACK_INBOX_DRY_RUN=true` default; classifier runs and records, but no side effects.
- Self-loop guard: prefilter on `subtype == "bot_message"` OR `user_id == bot_user_id` — belt-and-suspenders.
- No cost cap in G10 v1. Expected cost <$1/mo at single-team usage after prefilter; G11 candidate if multi-channel deployments warrant it.
- Item 10 (operator reactions as escalation/suppression) deferred to G11.

---

## Slice 1 — Routing + Listening Foundation (Items 1, 2)

**Goal:** Give the operator a config surface for which channels Guild listens in and which repo new work goes to. Gate the Events handler on this table. No classifier yet — just the plumbing that item 3 needs to be actionable.

### In-scope

- **Migration** — new `slack_channels` table:
  ```
  channel_id :string, primary_key: true
  default_repo :string, null: true  (FK→repos.full_name, nullable — operator sets later)
  enabled :boolean, default: true
  notes :text, null: true
  inserted_at, updated_at
  ```
- **Schema** — `lib/guild/schema/slack_channel.ex`: `use Ecto.Schema`, primary key `:channel_id` (string), `belongs_to :repo, Guild.Schema.Repo, foreign_key: :default_repo, references: :full_name, type: :string` (nullable). `changeset/2` casts and validates `channel_id` (required), `default_repo` (optional), `enabled`, `notes`.
- **Admin CRUD** — `/admin/slack-channels` modeled on the G8 `/admin/repos` page:
  - `GET /admin/slack-channels` — list all rows (channel_id, enabled badge, default_repo, notes). Add-channel form: channel_id text input, default_repo select (options from repos table), enabled toggle, notes textarea.
  - `POST /admin/slack-channels` — create. Validate channel_id required + not already existing.
  - `PATCH /admin/slack-channels/:channel_id/toggle` — flip enabled.
  - `DELETE /admin/slack-channels/:channel_id` — hard delete (no threads FK; a channel removed from Slack is truly gone).
  - Routes inside the existing `scope "/admin"` block, behind `:auth`.
  - Sub-nav on `/admin` index: add "Slack Channels" card alongside Repos/Workers/Integrations.
- **Events handler gate** — `lib/guild_web/controllers/slack_controller.ex` `dispatch_event/2`: when event type is `"message"` (not a reply), check `Guild.Repo.get(Guild.Schema.SlackChannel, channel_id)`. If nil or `enabled: false`, record the audit Event row (ADR 0016: record-all) with `thread_id: nil` and return — do not enqueue `SlackInboxWorker` (which doesn't exist yet in this slice; the gate just short-circuits to audit-only). If enabled: pass through to existing handler logic (no new behaviour in this slice — the classifier lands in Slice 2).
- Tests: `GET /admin/slack-channels` returns 200; `POST` creates row; `PATCH` toggles; `DELETE` removes row. Events handler test: message event for a non-configured channel records Event but does not trigger any classification path (stub the path with an assertion that no `SlackInboxWorker` job is enqueued).

### Stubbed at this slice

- The classifier itself (Slice 2).
- New-work and reference actions (Slice 3).
- `/admin/slack-inbox` review surface (Slice 4).

### ADRs required

ADR 0017 (already proposed alongside this plan) — accepted before Slice 2 is dispatched.

### Acceptance criteria

- `mix test --exclude e2e` green.
- `slack_channels` table exists with correct columns.
- Operator can add/toggle/delete channel configs from `/admin/slack-channels`.
- Message events for channels not in `slack_channels` (or with `enabled: false`) short-circuit to audit-only.

### Depends on

G9 main. No other slices.

### Estimate

~200 LOC (migration + schema + controller + templates + tests).

---

## Slice 2 — Classifier with Dry-Run (Items 3, 4, 8, 9)

**Goal:** Every top-level message in an enabled channel produces a classification Event with verdict, confidence, and reasoning. Nothing acts on it yet (dry-run default-on). Self-loop guard prevents Guild from classifying its own output.

### In-scope

- **Migration** — new `slack_inbox_events` table:
  ```
  id :binary_id, primary_key: true
  event_id :string, null: false        -- Slack event_id (dedup key)
  channel_id :string, null: false
  user_id :string, null: false
  user_display_name :string
  message_ts :string, null: false
  message_text :text                   -- truncated to 2000 chars
  verdict :string                      -- "new_work" | "refers_to_existing" | "noise" | "skipped" | "failed"
  confidence :float
  reasoning :text
  thread_id :binary_id, null: true           -- FK→threads.id; dual-purpose: classifier match for :refers_to_existing, backfilled by thread-creation path for :new_work
  action_taken :string, null: true     -- nil | "issue_created" | "reference_reply_posted" | "dry_run" | "noise"
  github_issue_url :string, null: true
  override_verdict :string, null: true
  inserted_at :utc_datetime_usec
  ```
  Unique index on `event_id`. Index on `(channel_id, user_id, inserted_at)` for rate-limit query.

- **Schema** — `lib/guild/schema/slack_inbox_event.ex`.

- **`Guild.LLM.OpenRouter`** — `lib/guild/llm/open_router.ex`. New module:
  ```elixir
  def complete(prompt, opts \\ [])
  ```
  POSTs to `https://openrouter.ai/api/v1/chat/completions` with:
  - `Authorization: Bearer <OPENROUTER_API_KEY>`
  - `HTTP-Referer: https://guild.inevitable.fyi` (OpenRouter requirement)
  - Model from `opts[:model]` or `Application.get_env(:guild, :openrouter_classifier_model, "openai/gpt-4o-mini")`
  - `max_tokens: 300`, `temperature: 0.1` (low temperature for consistent classification)
  - Returns `{:ok, text}` | `{:error, reason}`. Timeout: 10s.

- **`Guild.SlackInbox.classify/1`** — `lib/guild/slack_inbox.ex`:
  ```elixir
  def classify(%{message: msg, channel: channel, user: user, open_threads: threads})
  ```
  Builds the classifier prompt (see prompt design below), calls `Guild.LLM.OpenRouter.complete/2`, parses JSON, returns `{:ok, %{verdict:, confidence:, reasoning:, thread_id:}}` or `{:error, reason}`.

  **Classifier prompt design:**
  ```
  You are a work-routing assistant for an autonomous software engineering bot called Guild.
  Guild watches a Slack channel and decides whether each new top-level message represents:
  - "new_work": a request for Guild to perform a software task (fix a bug, add a feature, update docs, etc.)
  - "refers_to_existing": a message referencing work that Guild is already doing or has done
  - "noise": casual conversation, questions not directed at Guild, announcements, etc.

  Channel: #<channel_name> | Repo: <default_repo or "not configured"> | User: <display_name>

  Message:
  """
  <message_text>
  """

  Currently open work threads (most recent first):
  <for each thread: "- [<thread_id>] <repo>#<issue_number>: <one-line summary> (<state>, <time_ago>)">

  Return ONLY valid JSON. No markdown. No commentary.
  {
    "verdict": "new_work" | "refers_to_existing" | "noise",
    "confidence": <float 0.0-1.0>,
    "reasoning": "<≤200 chars explaining your verdict>",
    "matched_thread_id": "<thread UUID if refers_to_existing, else null — stored as thread_id in slack_inbox_events>"
  }
  ```

- **`Guild.Workers.SlackInboxWorker`** — `lib/guild/workers/slack_inbox_worker.ex`. Oban.Worker, queue `:slack_inbox`, `max_attempts: 2`, unique on `[event_id]`:
  - Prefilter (skip + no row): `subtype == "bot_message"` OR `user_id == bot_user_id` (read from `Application.get_env(:guild, :slack_bot_user_id)`) OR message length < 10 OR message starts with `/`.
  - Rate limit (inside worker, before OpenRouter call): query `slack_inbox_events` for same `(channel_id, user_id)` in last 60s. If found, return `:ok` (skip silently, no new row). Enforced here rather than at the Events handler so the handler stays thin and rate-limit state survives pod restarts.
  - Load the 20 most-recently-updated open threads (state in `[:noticed, :claimed, :executing, :pr_open]`, ordered by `updated_at desc`, limit 20).
  - Call `Guild.SlackInbox.classify/1`.
  - Insert `slack_inbox_events` row with verdict, confidence, reasoning, thread_id (= classifier's `matched_thread_id` for `:refers_to_existing`; null for others — backfilled later for `:new_work`).
  - If `SLACK_INBOX_DRY_RUN == "true"` (default): set `action_taken: "dry_run"`. Return `:ok`.
  - If not dry-run: pass to the action dispatch (Slice 3 adds this; stub with `action_taken: "noise"` for now).

- **Events handler wiring** — `lib/guild_web/controllers/slack_controller.ex`: when `event["type"] == "message"` AND no `event["thread_ts"]` (top-level) AND channel is in `slack_channels` enabled: enqueue `SlackInboxWorker` with `{event_id:, channel_id:, user_id:, user_display_name:, message_ts:, message_text:}`. Existing `resolve_work_thread` path (for replies) is unchanged.

- **Config** — `config/runtime.exs`: wire `OPENROUTER_API_KEY` → `Application.put_env(:guild, :openrouter_api_key, ...)`. Same for `OPENROUTER_CLASSIFIER_MODEL` (default `"openai/gpt-4o-mini"`), `SLACK_INBOX_DRY_RUN` (default `"true"`), `SLACK_INBOX_CONFIDENCE_THRESHOLD` (default `"0.7"`), `SLACK_BOT_USER_ID` (bot's Slack user ID — needed for self-loop guard; operator provisions).

- **Integration status** — extend `/admin/integrations` OpenRouter card: ready iff `OPENROUTER_API_KEY` present.

- **`k8s/secret.yaml`** key list: add `OPENROUTER_API_KEY`, `OPENROUTER_CLASSIFIER_MODEL`, `SLACK_INBOX_DRY_RUN`, `SLACK_INBOX_CONFIDENCE_THRESHOLD`, `SLACK_BOT_USER_ID`. Note: `k8s/secret.yaml` is documentation/template only — the live Secret is hand-managed via `kubectl patch` per the G8/G9 deploy runbook. Do not `kubectl apply` it.

- Tests: `SlackInboxWorker` with Bypass-mocked OpenRouter → correct `slack_inbox_events` row inserted; prefilter skips bot messages; rate limit skips second message from same user in 60s; dry-run sets `action_taken: "dry_run"` and does not call any GitHub/Slack action. `Guild.LLM.OpenRouter.complete/1` test with Bypass mock. `Guild.SlackInbox.classify/1` unit test with a mock OpenRouter response.

### Stubbed at this slice

- New-work and reference actions (Slice 3).
- `/admin/slack-inbox` review (Slice 4).
- Cost cap mechanism (G11).
- Per-channel confidence threshold (G11).
- `SLACK_BOT_USER_ID` can be provisioned post-deploy; self-loop guard degrades gracefully to subtype-only when absent.

### ADRs required

ADR 0017 — must be accepted before this slice is dispatched.

### Acceptance criteria

- `mix test --exclude e2e` green.
- `slack_inbox_events` table exists.
- Every qualifying top-level message in an enabled channel enqueues `SlackInboxWorker`.
- Bot messages and messages < 10 chars are not enqueued.
- Rate limit prevents double-classification within 60s.
- Dry-run mode records the classification but takes no action.
- `/admin/integrations` shows OpenRouter card status.

### Depends on

Slice 1 merged. ADR 0017 accepted.

### Estimate

~400 LOC (LLM module + classify + worker + schema + migration + config + tests). Most complexity is in the classifier prompt and JSON parsing.

---

## Slice 3 — New-Work + Reference Actions (Items 5, 6)

**Goal:** When `SLACK_INBOX_DRY_RUN=false`: `:new_work` messages become `bot-ready` GitHub issues; `:refers_to_existing` messages get a reply pointing to the work thread and appear as Events on `/threads/:id`.

### In-scope

- **`SlackInboxWorker` action dispatch** — extend the dry-run-false path:

  **`:new_work` action** (only when confidence ≥ threshold AND channel has `default_repo`):
  - Call `Guild.Adapters.GitHub.create_issue/2` (already exists): title = first line of message truncated to 80 chars; body = full message text + attribution footer `> @<user_display_name> in #<channel_name> on <date>`; labels = `["bot-ready"]`.
  - Insert a `slack_inbox_events` row with `action_taken: "issue_created"`, `github_issue_url` from the response.
  - Post a confirmation reply to the originating Slack message (using `post_message` with `thread_ts: message_ts` so the reply threads under the original message — NOT a new top-level post):
    `"Filed as [<repo>#<N>](<url>). I'll keep you posted in this thread."`
  - **Bridging originating message to the work thread:** When the GitHub webhook fires and creates the work thread (or when `ClaimWorker` creates it), the thread-creation path looks up `slack_inbox_events WHERE github_issue_url = <new_issue_url>`, backfills `thread_id = new_thread.id`, then inserts an `Event` row on the new thread (`source: "slack"`, `event_type: "slack.message"`, `body: message_text`, `thread_id: new_thread.id`) so the originating Slack message appears first in the `/threads/:id` timeline. This is what makes the Slack conversation and the work thread feel contiguous to the operator.
  - If `default_repo` is nil: set `action_taken: "noise"` (cannot file without a repo; log a warning).
  - If confidence < threshold: set `action_taken: "noise"` (record-only, no issue).

  **`:refers_to_existing` action** (only when confidence ≥ threshold AND `thread_id` resolves to a live thread):
  - Record the Slack message as an `Event` row on the matched thread (`source: "slack"`, `event_type: "slack.reference"`, `thread_id: thread_id`).
  - Post a reply to the originating Slack message (threaded reply, `thread_ts: message_ts`):
    `"@<user_display_name> — this looks like ongoing work: [Open in Slack](<app_redirect_url>). Continuing there."` where `app_redirect_url` uses the matched thread's `slack_channel` + `slack_thread_ts`.
  - If the matched thread has no `slack_thread_ts` (no prior Slack post for that work thread): reply without the Slack link, just `"@<user> — this looks like ongoing work on [<repo>#<issue>](<github_url>)."`
  - Set `action_taken: "reference_reply_posted"`.

  **`:noise`**: `action_taken: "noise"`. No side effects.

  **Confidence below threshold for any verdict**: `action_taken: "noise"` regardless of verdict.

- **`post_message` to originating channel** — `Guild.Adapters.Slack.post_message/3` already accepts a `channel` argument. Pass the originating `channel_id` explicitly (not the default `SLACK_CHANNEL_ID`). Verify this works (the bot must be a member of the originating channel; it is, by definition, because Slack only delivers events from channels the bot is in).

- Tests: `SlackInboxWorker` with `SLACK_INBOX_DRY_RUN=false` and a Bypass-mocked OpenRouter returning `:new_work` → GitHub issue created (Bypass-mocked GitHub) + Slack reply posted (Bypass-mocked Slack). `:refers_to_existing` → Event row inserted on matched thread + Slack reply posted. `:noise` → no side effects. Confidence below threshold → no side effects regardless of verdict.

### Stubbed at this slice

- Override actions from `/admin/slack-inbox` (Slice 4).
- Closing/withdrawing a false-positive issue (G11).

### ADRs required

None (beyond ADR 0017 already accepted).

### Acceptance criteria

- `mix test --exclude e2e` green.
- With dry-run off: `:new_work` → GitHub issue + Slack confirmation reply.
- With dry-run off: `:refers_to_existing` → Event on matched thread + Slack reference reply.
- Confidence below threshold → no side effects for any verdict.

### Depends on

Slice 2 merged.

### Estimate

~250 LOC (action dispatch + tests). Complexity is in edge cases (no default_repo, no slack_thread_ts on matched thread, confidence below threshold).

---

## Slice 4 — Operator Review Surface (Item 7)

**Goal:** Make the classification stream visible and actionable. Operators can see what Guild is deciding and override wrong classifications.

### In-scope

- **`/admin/slack-inbox`** — new admin page:
  - `GET /admin/slack-inbox`: list `slack_inbox_events` ordered by `inserted_at desc`, limit 50. Columns: timestamp, channel_id, user_display_name, message excerpt (first 80 chars), verdict badge (color-coded), confidence (e.g. "92%"), action_taken, reasoning (expandable on click or truncated to 200 chars), override controls.
  - Per-row override buttons (form POSTs, no JS required):
    - "File as new work" — `POST /admin/slack-inbox/:id/reclassify` with `{verdict: "new_work"}`. Runs the `:new_work` action immediately (regardless of dry-run flag; override is an explicit operator decision). Sets `override_verdict: "new_work"` on the row.
    - "Mark as noise" — sets `override_verdict: "noise"`, no other action.
    - (For `:refers_to_existing` override: a more complex flow — out of scope for this slice; just "Mark as noise" is sufficient for G10.)
  - Sub-nav: add "Slack Inbox" link to `/admin` index alongside Repos/Workers/Integrations/Slack Channels.
  - Routes in the existing `scope "/admin"` block, behind `:auth`.

- **`AdminController.slack_inbox/2`** and `AdminController.reclassify_inbox_event/2` actions.
- Template: `admin_html/slack_inbox.html.heex`.

- Tests: `GET /admin/slack-inbox` returns 200 with seeded events; `POST /admin/slack-inbox/:id/reclassify` with `new_work` triggers the action and sets `override_verdict`.

### Stubbed at this slice

- Full refers_to_existing override UI (thread picker — G11).
- Pagination (50 items is fine for G10).
- Bulk override actions.

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- `/admin/slack-inbox` renders classification stream with reasoning.
- "File as new work" override creates the GitHub issue and sets `override_verdict`.
- "Mark as noise" sets `override_verdict: "noise"`.

### Depends on

Slice 2 merged (needs `slack_inbox_events` table). Can run in parallel with Slice 3.

### Estimate

~200 LOC (controller + template + tests).

---

## Slice 5 — Driver Live Dry-Run + Targeted Fixes (Judgment-Gated Close)

**Goal:** With the classifier running dry-run in the live workspace, validate that Guild's judgment matches the driver's. Flip to live when confident. Fix what's cheap; close G10 when the bar is met.

### Dry-run checklist (driver executes)

**Provision:**
- Add `OPENROUTER_API_KEY` to the live k8s Secret; roll the deployment.
- Add the `#guild` channel (or equivalent) to `/admin/slack-channels` with `default_repo` set.
- Confirm `/admin/integrations` shows OpenRouter card as ✓ ready.
- Confirm `SLACK_INBOX_DRY_RUN=true` is set (default).

**Dry-run validation (≥3 days, or until confident):**
- Post a clear new-work request: "can you add a CHANGELOG entry for last week's release?" → `/admin/slack-inbox` should show `new_work` with confidence > 0.7.
- Post a reference: "did that typo fix ship?" → should show `refers_to_existing` matching the relevant thread.
- Post noise: "good morning everyone" → should show `noise`.
- Confirm bot messages (Guild's own `:done` replies, confirmation replies) produce no classification rows (self-loop guard working).
- Review reasoning for any surprises. Adjust confidence threshold via env if needed.

**Go live:**
- Set `SLACK_INBOX_DRY_RUN=false` in the live Secret; roll the deployment.
- Post a new-work request. Confirm: GitHub issue created with `bot-ready` label, confirmation reply threaded under the original message, thread appears on `/threads`, worker pipeline runs.
- Post a reference. Confirm: Event row appears on the referenced `/threads/:id` timeline, reply is posted.
- Post noise. Confirm: no GitHub issue, no reply, but classification Event recorded.

**Override surface:**
- In `/admin/slack-inbox`, find a classification that was wrong. Use "File as new work" or "Mark as noise" override. Confirm the action fires correctly.

### What to capture

- Classifications that don't match human judgment (false positives and negatives).
- Any self-loop — Guild classifying its own message (critical bug if seen).
- Slack reply text that feels wrong ("looks like" hedging too weak or too strong).
- Any uncaught errors in `SlackInboxWorker` (check `/jobs` for failed jobs).

### Fix scope

Blocking defects and wince-worthy moments ≤ 1–2 hours. Classifier prompt tuning (if needed) is a fast edit. Larger items → G11.

### ADRs required

None.

### Acceptance criteria

Driver judgment: "Guild notices new requests, threads them to GitHub issues, routes references back to the right Slack thread, and ignores chatter — without classifying its own messages." Evidenced by dry-run checklist + live-fire observations in ROADMAP G10 Done.

### Depends on

Slices 1–4 merged; `OPENROUTER_API_KEY` provisioned; dry-run validation period complete.

### Estimate

Dry-run: 3–7 days. Live-fire: 1–2 hours. Fixes: judgment-scoped (0–1 day). Close: driver.

---

## Slice execution order summary

| Slice | Items | ADRs | Notes |
|-------|-------|------|-------|
| 1 | `slack_channels` table + CRUD + Events gate (items 1, 2) | — | Foundation; must go first |
| 2 | Classifier + dry-run + self-loop guard (items 3, 4, 8, 9) | ADR 0017 (accept first) | Pure record; no side effects |
| 3 | New-work + reference actions (items 5, 6) | — | Can start when Slice 2 merged |
| 4 | `/admin/slack-inbox` review surface (item 7) | — | Can run in parallel with Slice 3 |
| 5 | Driver dry-run + live-fire + targeted fixes | — | Judgment-gated; needs all prior slices + dry-run validation |

**G10 closes** when the driver records their go/no-go in the ROADMAP G10 Done entry with dry-run evidence.
