# G7 Slice 2 — Operator UI Polish for the Demo Screen

Repo: jhgaylor/guild. Branch: g7/slice-2-ui-polish.
TESTS REQUIRED. Read existing templates/LiveViews before editing.
Do NOT create scratch docs outside plan/g7-slice-2/.
## 1. Home page — lib/guild_web/controllers/page_html/home.html.heex
Replace with a tight, public-facing pitch. Keep the existing route (public).
Content: a Guild title, two short sentences (e.g. "Guild is an autonomous agent
that watches your GitHub repos for bot-ready issues, claims them, and ships PRs.
Operators steer it from Slack and observe it in the UI."), then prominent links
to /threads (Operator threads) and /jobs (Oban queue — both require operator
auth). Plain HTML, no decorative noise.
## 2. Interleaved thread timeline — lib/guild_web/live/thread_live.ex + .html.heex
Replace the four separate sections (Events, Context Notes, Decisions, Artifacts)
with a SINGLE merged chronological feed. In the LiveView: load events, context_notes,
decisions_log entries, and artifacts for the thread; normalize each to a small
%{timestamp, kind, summary, metadata} map; sort by timestamp asc (oldest first);
assign as :timeline_entries. Kinds: :event, :note, :decision, :artifact.
Summary: event -> event_type; note -> note_type + truncated body; decision ->
action + params summary; artifact -> artifact_type + external_id (as link if url).
In the template: render one list; each row shows kind badge, summary, timestamp.
Keep the Owner/Created/Updated info card at the top (do not remove it).
"Snapshot trimmed" marker: for :decision rows where metadata.context_snapshot is nil,
add a small grey "snapshot trimmed" tag next to the decision summary.
## 3. "Recent activity" strip — threads index
Threads index is at lib/guild_web/controllers/thread_html/index.html.heex.
Determine where threads are assigned (PageController? a different controller or
LiveView — read the router first). In the controller/LiveView assigns: query threads
ORDER BY COALESCE(state_entered_at, updated_at) DESC LIMIT 5 for the recent_activity
list. Pass time_ago as a string per entry (add Guild.Format.time_ago/1 or use an
existing helper if one exists — check lib/guild_web/ for existing format helpers).
Add a small "Recent activity" panel ABOVE the threads table: "Thread <anchor_id>
entered :<state> <time_ago>". Four or five lines of HTML, tight.
## Tests (REQUIRED)
Home: GET / returns 200, body contains "Guild" title and links to /threads and /jobs.
Thread show: GET /threads/:id renders merged timeline including all four kinds; a
decision row with context_snapshot nil shows "snapshot trimmed" marker.
Threads index: GET /threads with credentials renders "Recent activity" panel with
the most recently entered thread.
mix test --exclude e2e green. PR open on g7/slice-2-ui-polish.
