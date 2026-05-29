# G5 Slice 3 — Slack Human-in-the-Loop (hold/resume/abandon)

Repo: jhgaylor/guild. Branch: g5/slice-3-slack-hitl. ADR 0015 accepted.
Schema at lib/guild/schema/ (singular). Read existing code before editing.
Do NOT create scratch/planning docs outside plan/g5-slice-3/.
## Migration + lib/guild/schema/thread.ex
Migration: add held :boolean, default: false, null: false to threads table.
Thread schema: add field :held, :boolean, default: false; cast in changeset.
## GuildWeb.SlackController + route
POST /slack/commands OUTSIDE :auth pipeline (auth via Slack signature only).
Raw body: check how lib/guild_web/endpoint.ex + webhook_controller.ex capture
:raw_body via CacheBodyReader — replicate that mechanism for this route.
Verify Slack v0 signature: expected = "v0=" <> hex(HMAC-SHA256(SLACK_SIGNING_SECRET,
"v0:" <> ts <> ":" <> raw_body)); constant-time compare (:crypto.hash_equals) to
X-Slack-Signature. Reject if X-Slack-Request-Timestamp older than 5 min.
FAIL-SECURE: if SLACK_SIGNING_SECRET absent, reject all inbound (403).
Parse slash command form params: command + text -> subcommand + issue_number.
Call Guild.Control.hold/resume/abandon. Respond 200 JSON ephemeral ack.
## Guild.Control (lib/guild/control.ex)
hold(issue_number_or_uuid): set thread.held = true; cancel pending Oban
ClaimWorker jobs for this thread (query oban_jobs by args, Oban.cancel_job/1).
resume(issue_number_or_uuid): set held = false.
abandon(issue_number_or_uuid): call Meta.update_thread_state to :abandoned
(add :abandon event + :abandoned as terminal state if not present in StateMachine);
cancel pending Oban job. Meta already clears owner on :abandoned (ADR 0014).
Resolve thread: anchor_type: :github_issue, anchor_id: issue_number; or UUID.
## lib/guild/reconcile.ex — Pass A + Pass C
Add where: t.held == false (or is_nil / false guard) to Pass A query and Pass C
query so held threads are skipped by both.
## k8s/secret.yaml
Add SLACK_SIGNING_SECRET (placeholder base64, comment: required for /guild commands).
## Tests + Done-when
Valid sig + "hold <issue#>" -> thread.held true + job cancelled. Invalid sig -> 403.
Missing SLACK_SIGNING_SECRET -> 403. "abandon <issue#>" -> :abandoned + owner nil.
"resume <issue#>" -> held false. Pass A/C skip held threads.
mix test --exclude e2e green. PR open on g5/slice-3-slack-hitl.
