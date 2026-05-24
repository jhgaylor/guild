# G3 Slice 2 — Live Claiming from Webhooks
Repo: jhgaylor/guild. Branch: g3/slice-2-live-claiming (off main).
Read schema/{thread,event,artifact}.ex, claim_seed.ex, webhook_controller.ex first.

## lib/guild/claiming.ex — Guild.Claiming.claim_issue/2(repo, issue_number)
1. get_issue/2 via GitHub adapter. 2. Upsert Thread (on_conflict: :nothing,
conflict_target: [:anchor_type, :anchor_id]). 3. StateMachine transitions:
:unnoticed→:noticed→:claimed. 4. Insert seed Event (idempotency_key:
"claim_seed:#{repo}:#{number}", on_conflict: :nothing). 5. Dispatch Fountain conv
with vault_id = Application.get_env(:guild, :worker_vault_id). 6. Insert
fountain_conversation Artifact (external_id: conv_id). 7. Transition :claimed→
:executing. assign_to_self OMITTED (accepted G3 limitation).
Returns {:ok, %{thread: t, fountain_conv_id: id}} | {:error, reason}.
Stays stubbed: reconciliation (:executing → :pr_open handled in Slice 3).

## lib/mix/tasks/guild/claim_seed.ex
Delegate 7-step body to Guild.Claiming.claim_issue/2. Keep OptionParser + Mix.shell
error reporting. Remain idempotent, exit-1 on missing args.

## lib/guild_web/controllers/webhook_controller.ex + config/runtime.exs
On issues.opened / issues.labeled: extract body["issue"]["labels"]. If "bot-ready"
present AND no thread in claimed/executing/pr_open for this anchor: Task.start to
call Guild.Claiming.claim_issue/2. Log result; return 200 immediately.
config/runtime.exs: config :guild, worker_vault_id: System.get_env("GUILD_WORKER_VAULT_ID", "")

## Tests + Done-when
Guild.Claiming unit tests (TestAdapter): happy path → thread :executing + artifact +
conv_id; idempotent call → no double-dispatch. Webhook test: bot-ready label →
claim_issue called (set :claim_async false in test env to make Task synchronous).
mix test --exclude e2e green. PR open on g3/slice-2-live-claiming.
