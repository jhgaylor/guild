# G4 Slice 3 — Retention, Summarization, LiveView Auth

Repo: jhgaylor/guild. Branch: g4/slice-3-retention-summarization-liveauth.
Three parts, three commits, one PR. Read current schema before implementing.
## PART A — ADR 0009 + Guild.Retention
Update decisions/0009-decisions-log-retention.md: keep full rows for most recent
@max_rows 200 decisions per thread; null context_snapshot on older rows (keep
action/params/timestamps). Guild.Retention.trim_decisions_log(thread_id): query
decisions_log ordered by id desc, skip first 200, update remainder setting
context_snapshot=nil. Hook: call after thread reaches :done in Guild.Reconcile.
If decisions_log table does not exist, adapt the principle to whatever heavy-blob
column exists on the nearest equivalent table.
## PART B — ADR 0007 + Guild.Summarization
Update decisions/0007-context-assembly-strategy.md: trigger summarization when a
thread's context_notes count > @threshold 50. Guild.Summarization.maybe_summarize/1:
count notes, no-op if under threshold. Over threshold: POST assembled context to
Fountain (reuse existing HTTP/Fountain adapter in codebase — do not add dependencies);
write response as ContextNote with note_type: :summary; mark superseded notes
note_type: :archived. Hook into Guild.Reconcile.reconcile_thread/1.
## PART C — LiveView socket auth
Plug.BasicAuth in :auth pipeline guards HTTP dead-render; WebSocket upgrade bypasses
router pipelines. Fix: wrap ThreadLive (and any other browser live routes) in a
live_session with on_mount: {GuildWeb.OperatorAuth, :require_auth}. Create
lib/guild_web/live/operator_auth.ex implementing on_mount/4: read Authorization
header from socket connect_info (configure socket :connect_info if needed), validate
via Plug.BasicAuth; halt/redirect if invalid. Test: unauthenticated live mount of
/threads/:id is rejected (receives redirect or halt, not mounted).
## Tests + Done-when
mix test --exclude e2e green. PR open on g4/slice-3-retention-summarization-liveauth.
