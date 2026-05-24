# G3 Slice 3 — Guild.Reconcile GenServer
Repo: jhgaylor/guild. Branch: g3/slice-3-reconcile (off main).
Read schema/{thread,event,artifact}.ex, state_machine.ex, primitives/meta.ex first.
## lib/guild/reconcile.ex
GenServer. init: :timer.send_interval(30_000, self(), :reconcile).
Export reconcile_all/0 + reconcile_thread/1 as public API.
handle_info(:reconcile) — two passes:
Pass A (:executing → :pr_open): find threads state=executing with fountain_conversation
artifact. Per thread: Fountain.get_status(conv_id) → {:ok, :idle} else skip.
GitHub.list_pull_requests(repo, state: "open") → find PR body matching
~r/(Closes|Fixes) ##{anchor_id}/i. If found: insert pull_request Artifact +
Meta.update_thread_state(:pr_opened).
Pass B (:pr_open → :done): find threads state=pr_open with pull_request artifact.
Per thread: query events for event_type="pull_request.merged" AND thread_id. If found:
Meta.update_thread_state(:pr_merged).
Log info on transitions. Log warn on errors; do not crash GenServer.
Stays stubbed: multi-worker arbitration, Linear/Slack hooks.
## lib/guild/application.ex
Add {Guild.Reconcile, []} to supervision tree after Repo.
## test/guild/e2e/contribute_md_test.exs
Remove Step 3.5 manual block + TODO(reconcile) comment.
Add Guild.Reconcile.reconcile_all() call before Step 4 assertion.
## Tests (test/guild/reconcile_test.exs)
DataCase + Bypass (Fountain) + TestAdapter (GitHub).
- :executing + Fountain idle + matching PR → :pr_open + artifact inserted.
- :pr_open + pull_request.merged event → :done.
- :executing + Fountain running → no transition.
- :executing + Fountain idle + no matching PR → no transition.
## Done-when
mix test --exclude e2e green. E2E still passes. PR open on g3/slice-3-reconcile.
