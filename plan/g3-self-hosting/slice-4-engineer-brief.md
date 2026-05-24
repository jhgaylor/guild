# G3 Slice 4 — Integration Test + ROADMAP Close
Repo: jhgaylor/guild. Branch: g3/slice-4-integration-test (off main).
Read webhook_controller.ex, claiming.ex, reconcile.ex, test_helper.exs, state_machine.ex.
Stays stubbed: live Fountain/GitHub — operator runs live-fire after merge.

## test/guild/integration/webhook_to_done_test.exs
@moduletag :integration. No live external calls; TestAdapter + fake payloads.
Setup: Application.put_env(:guild, :claim_async, false) to make webhook claiming sync.
Configure TestAdapter: dispatch_conversation→{:ok,"fake-conv-id"},
get_status→{:ok,:idle}, list_pull_requests→{:ok,[%{"number"=>1,"html_url"=>"...pr1",
"body"=>"Closes #3"}]}.
Step 1: POST /api/webhooks/github — issues.opened + label "bot-ready" + issue #3.
Sign body with HMAC using Application.get_env(:guild, :github_webhook_secret, "test").
Assert 200 + Event row inserted in DB.
Step 2: Assert Thread state="executing" + fountain_conversation artifact exists.
Step 3: Guild.Reconcile.reconcile_all(). Assert Thread :pr_open + pull_request artifact.
Step 4: POST /api/webhooks/github — pull_request action=closed + merged=true, PR#1.
Sign payload. Assert 200 + pull_request.merged Event inserted.
Step 5: Guild.Reconcile.reconcile_all(). Assert Thread state="done".

## test/test_helper.exs + ROADMAP.md + runbook
test_helper.exs: add :integration to ExUnit.configure(exclude: [...]) with :e2e.
ROADMAP.md: move G3 Now→Done; Gated: G3 closed; Next: pending G4 framing.
plan/g3-self-hosting/verify-g3-live.md: operator runbook — open issue on
jhgaylor/guild, label bot-ready, watch /threads as Guild ingests→claims→reconciles.

## Done-when
mix test --exclude e2e --exclude integration green (246 baseline).
mix test --include integration passes full webhook→:done without live calls.
PR open on g3/slice-4-integration-test.
