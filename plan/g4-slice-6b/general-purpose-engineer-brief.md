# G4 Slice 6b — Multi-Worker/Multi-Repo Implementation

Repo: jhgaylor/guild. Branch: g4/slice-6b-multiworker-impl.
Implements ADRs 0011/0012/0013. Single-worker behavior preserved via seeded rows.
## lib/guild_web/controllers/webhook_controller.ex
On incoming event: look up body's repo full_name in repos table. If found + enabled,
pass worker_id into ClaimWorker job args: ClaimWorker.new(%{repo: r, issue_number: n,
worker_id: row.worker_id}) |> Oban.insert!(). If not found or disabled, log a warning
and return 200 no-op (do not drop the 200). GUARDRAIL: after deploy seeds must exist.
## lib/guild/release.ex (or existing release module)
Add Guild.Release.seed/0 that upserts default worker row (GUILD_IMPLEMENTER_AGENT_ID,
GUILD_WORKER_VAULT_ID) and default repos row ("jhgaylor/guild" or GITHUB_REPO env) using
on_conflict: :nothing. Call seed/0 after migrate/0 in release steps so default rows
always exist post-deploy. Check if lib/guild/release.ex already exists before creating.
## lib/guild/workers/claim_worker.ex + lib/guild/claiming.ex
ClaimWorker.perform/1 receives worker_id from args. Inside the existing advisory-lock
transaction add CAS: Repo.update_all(from(t in Thread, where: t.id == ^id and
is_nil(t.owner)), set: [owner: worker_id]). If 0 rows updated: {:cancel,:already_claimed}.
If 1 row updated: proceed. Thread worker_id from job args through claim_issue/3 to dispatch.
## lib/guild/claiming.ex — per-worker credentials
Look up Guild.Schema.Worker by worker_id. Use row.fountain_agent_id + row.vault_id for
Fountain dispatch. Fallback to env GUILD_IMPLEMENTER_AGENT_ID/GUILD_WORKER_VAULT_ID when
row absent or worker_id nil. No crash on missing data.
## Tests + Done-when
(a) Two ClaimWorkers same thread different worker_ids: one wins CAS, one {:cancel,...}.
(b) Webhook for configured repo enqueues job with correct worker_id; unconfigured repo
gets 200 + warning (no job enqueued). (c) Dispatch uses worker row creds, env fallback.
mix test --exclude e2e green. PR open on g4/slice-6b-multiworker-impl.
