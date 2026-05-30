# G6 Slice 2 — Slack Interactive Buttons + Operator Digest

Repo: jhgaylor/guild. Branch: g6/slice-2-slack-ux.
TESTS ARE REQUIRED for every new behavior — do not skip them.
Read existing code (slack adapter, slack_controller, reconcile, oban config) first.
Do NOT create scratch docs outside plan/g6-slice-2/.
## 1. Block Kit buttons — lib/guild/adapters/slack.ex
Extend post_message/2 to accept post_message(channel, text, opts \\ []).
When opts[:blocks] is present, include it in the Slack API JSON payload alongside
text. Backward-compatible: opts absent = unchanged behavior.
From reconcile Pass A (pr_open promote): send blocks with section text + actions
block: Hold button (action_id "guild_hold", value = issue_number as string) and
Abandon button (action_id "guild_abandon", value = issue_number as string).
From Pass B (done): blocks with section text + View button (action_id "guild_view",
value = thread.id, url = threads/:id absolute URL via Endpoint config).
## 2. POST /slack/interactions — lib/guild_web/controllers/slack_controller.ex
Add interactions/2 action. Route: post "/interactions" inside existing /slack scope
(outside :auth). Same v0 HMAC + timestamp + fail-secure as commands/2. Extract
shared HMAC helpers into private functions called by both actions.
Slack sends application/x-www-form-urlencoded with a payload field (JSON). Parse
params then Jason.decode! payload. Iterate actions list: action_id "guild_hold" ->
Guild.Control.hold(value); "guild_abandon" -> Guild.Control.abandon(value);
"guild_view" -> no-op. Respond 200 with ephemeral JSON ack.
## 3. Guild.Digest — lib/guild/digest.ex
send_digest/0: query thread counts grouped by state. Compute stuck count (threads
where COALESCE(state_entered_at, updated_at) < now - threshold and not held).
Format Slack message: shipped (done count), in-flight (executing+pr_open), stuck
count, held count, worst 3 stuck threads with anchor_id + age. Post via
Guild.Adapters.Slack.post_message/2 (graceful no-op if Slack unconfigured).
Add Oban Cron entry at "0 9 * * *" (09:00 UTC daily, module constant @cron_schedule)
firing Guild.Digest. Look at lib/guild/application.ex + config/ for how Oban Cron
is configured in this project (Oban.Plugins.Cron or Oban.Pro.Plugins.DynamicCron).
## Tests (REQUIRED — Bypass for HTTP, Oban :inline for jobs)
Adapter: post_message with blocks: opt sends blocks in HTTP payload (Bypass assert).
Interactions: valid v0-signed payload with guild_hold + issue# -> thread.held true.
  Invalid signature -> 403. Missing SLACK_SIGNING_SECRET -> 403.
Digest: threads in mixed states -> Slack receives message with correct counts (Bypass).
Reconcile Pass A/B: transitions still pass; blocks include expected action_ids.
mix test --exclude e2e green. PR open on g6/slice-2-slack-ux.
