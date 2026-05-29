# G5 Slice 1 — Oban Web + Thread Timeline

Repo: jhgaylor/guild. Branch: g5/slice-1-oban-web-timeline.
Schema modules live at lib/guild/schema/ (singular, not schemas/).
## mix.exs — queue visibility at /jobs
Try {:oban_web, "~> 2.11"} from public hex (free/open-source since 2024; NO
license key, NO private repo config). If mix deps.get resolves it: in router.ex
add import Oban.Web.Router and oban_dashboard "/jobs" inside the :auth pipeline.
If oban_web does NOT resolve from public hex freely, FALL BACK to a minimal custom
view: a /jobs LiveView querying oban_jobs rows grouped by state (available,
executing, retryable, completed, cancelled) showing args + attempts + errors.
Note in a commit message which path was taken. No license or private repo config.
## lib/guild_web/router.ex
Mount /jobs inside :auth pipeline (operator-gated, 401 unauthenticated).
## lib/guild_web/live/thread_live.ex + index/show templates
/threads index: add owner column (thread.owner, dash if nil).
/threads/:id detail: render a chronological timeline interleaving —
  Events: type, payload summary (truncate if large), timestamp
  decisions_log entries: action, params, indicator when context_snapshot is nil
  ContextNotes: note_type, body (truncated), timestamp
  Artifacts: type, external_id as link (PR URL for pull_request type, Fountain
    conv link for fountain_conversation type), inserted_at
  Current owner: shown as header field
Derive state-transition history from Event types/timestamps (no new column).
Preload all associations on the Thread query for the show view.
## Tests
/jobs unauthenticated -> 401. /jobs authenticated -> 200.
/threads/:id renders: events section, artifacts section, context_notes section.
No behavior change to claiming, reconcile, or webhooks.
mix test --exclude e2e green. PR open on g5/slice-1-oban-web-timeline.
