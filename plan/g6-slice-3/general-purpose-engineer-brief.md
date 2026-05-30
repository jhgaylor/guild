# G6 Slice 3 — Bidirectional Sync (Linear + Slack Events)

Repo: jhgaylor/guild. Branch: g6/slice-3-bidirectional-sync. ADR 0016 accepted.
TESTS REQUIRED for every new behavior. Read existing code before editing.
Do NOT create scratch docs outside plan/g6-slice-3/.
## 1. lib/guild_web/controllers/linear_controller.ex + route
New LinearController with webhooks/2. Route: scope "/linear" -> post "/webhooks"
outside :auth pipeline. Raw body via CacheBodyReader (replicate GitHub/Slack pattern).
Verify Linear-Signature: HMAC-SHA256 raw_body with :linear_webhook_secret (wired
from LINEAR_WEBHOOK_SECRET in runtime.exs, same pattern as :slack_signing_secret).
Constant-time compare (:crypto.hash_equals). Fail-secure 403 if header missing or
secret unset. On valid: parse JSON, insert Event row: event_type "linear." <> type
(e.g. linear.issue_updated, linear.comment_created). Resolve thread_id by anchor
lookup if payload has a GitHub issue number reference — otherwise nil. NO state
machine calls. k8s/secret.yaml: add LINEAR_WEBHOOK_SECRET (placeholder + comment:
Linear team admin configures webhook URL out-of-band).
## 2. GuildWeb.SlackController.events/2 + route
Add events/2 to SlackController. Route: post "/events" inside /slack scope, outside
:auth. Pass body through shared verify_slack_request/1 helper (EVEN for
url_verification — sign check is defense-in-depth). Then dispatch by type:
  url_verification: respond 200 plain text with challenge value.
  reaction_added WHERE reaction=="stop_sign" AND item.type=="message": look up
    Artifact where url == "slack://" <> item.channel <> "/" <> item.ts. If found,
    call Guild.Control.hold(artifact.thread_id) passing the UUID directly (Guild.Control
    already resolves UUIDs). Log on error, do not crash.
  All other events: insert Event row event_type "slack." <> event.type, thread_id
    nil (or resolved if relates to a slack_message artifact). Respond 200 empty body.
## 3. slack_message artifact creation in lib/guild/adapters/slack.ex + reconcile.ex
Change post_message to parse the Slack chat.postMessage JSON response. On success
(ok==true): return {:ok, %{channel: channel, ts: ts}}. Existing {:ok, :not_configured}
and error paths unchanged. In reconcile Pass A (pr_open) and Pass B (done): when
post_message returns {:ok, %{channel: c, ts: ts}}, insert Artifact with
artifact_type "slack_message", source "slack", external_id ts,
url "slack://" <> c <> "/" <> ts, thread_id thread.id. Use on_conflict: :nothing
keyed on (source, external_id) for idempotency. Graceful no-op on :not_configured
or error — no artifact.
## Tests (REQUIRED — Bypass for HTTP, Ecto sandbox for DB)
LinearController: valid sig + issue payload -> linear.issue_updated Event inserted.
  Invalid sig -> 403. Missing LINEAR_WEBHOOK_SECRET -> 403.
SlackController.events: valid sig + url_verification -> challenge returned.
  valid sig + reaction_added stop_sign on slack_message artifact -> thread.held true.
  valid sig + reaction on non-Guild message -> Event row, held unchanged.
  Invalid sig -> 403.
Slack adapter: post_message returns {:ok, %{channel: c, ts: ts}} on success (Bypass
mock). Pass A creates slack_message Artifact with correct url after pr_open post.
mix test --exclude e2e green. PR open on g6/slice-3-bidirectional-sync.
