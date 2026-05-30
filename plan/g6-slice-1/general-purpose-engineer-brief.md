# G6 Slice 1 — Polish Foundations (4 carry-overs)

Repo: jhgaylor/guild. Branch: g6/slice-1-polish.
Read existing code before editing. Do NOT create scratch docs outside plan/g6-slice-1/.
## 1. Linear :executing transition (lib/guild/claiming.ex)
After thread reaches :executing in claim_issue/3, call:
  Guild.Adapters.Linear.update_issue(thread.linear_issue_id, %{stateId: state_id})
where state_id = Guild.Adapters.Linear.state_id(:in_progress).
Gate: skip if thread.linear_issue_id is nil or state_id is nil (graceful no-op).
Look at how Pass B in lib/guild/reconcile.ex wires the :done Linear update for the
EXACT call shape and key names (camelCase atom :stateId, NOT :state_id).
## 2. Pass D terminated flag (artifacts table)
Migration: add terminated :boolean, default: false, null: false to artifacts.
lib/guild/schema/artifact.ex: field :terminated, :boolean, default: false + cast.
lib/guild/reconcile.ex Pass D: add where: not a.terminated to the query so already-
terminated artifacts are skipped entirely (no get_status call). On successful
Fountain.terminate_conversation OR when get_status returns :terminated, do:
Repo.update!(artifact_changeset(artifact, %{terminated: true})).
## 3. state_entered_at (threads table)
Migration: add state_entered_at :utc_datetime_usec, null: true to threads.
lib/guild/schema/thread.ex: field + cast. State transition is in
lib/guild/primitives/meta.ex (NOT lib/guild/meta.ex) — update update_thread_state
to set state_entered_at = DateTime.utc_now() on every transition.
Pass C in lib/guild/reconcile.ex: replace updated_at cutoff with state_entered_at;
fall back to updated_at when state_entered_at is nil (pre-existing rows).
Threads index badge + detail banner: compute stuck from state_entered_at (same
nil fallback to updated_at).
## 4. Dockerfile OTP base-image bump
Bump base image to OTP 28.1+ (e.g. hexpm/elixir with OTP >= 28.1). No other
Dockerfile changes. Eliminates the OTP 28.0 regex-recompile perf warning.
## Tests + Done-when
claim_issue Linear :executing fires when linear_issue_id + LINEAR_STATE_IN_PROGRESS_ID
present; graceful no-op when either absent. Pass D skips artifacts with terminated:
true (no get_status call); successful termination flips terminated: true. Pass C
uses state_entered_at, falls back to updated_at when nil.
mix test --exclude e2e green. PR open on g6/slice-1-polish.
