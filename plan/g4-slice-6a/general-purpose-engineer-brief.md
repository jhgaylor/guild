# G4 Slice 6a — Multi-Worker/Multi-Repo ADRs + Schema

Repo: jhgaylor/guild. Branch: g4/slice-6a-multiworker-adrs-schema.
ADRs are Accepted (decisions delegated). No runtime behavior change in this slice.
## decisions/0011-claiming-arbitration.md (rewrite stub as Accepted)
Decision: advisory lock (Slice 1) + optimistic CAS on new threads.owner (string,
nullable). ClaimWorker tx: claim only if threads.owner IS NULL, set owner=worker_id.
Already-owned -> {:cancel, :already_claimed}. Reject: centralized leader (extra
infra), queue-pull (Oban already serializes). Consequence: threads.owner this slice.
## decisions/0012-per-worker-credentials.md (rewrite stub as Accepted)
Decision: workers config table mapping worker_id -> fountain_agent_id, vault_id,
github_installation_id (nullable). Dispatch looks up worker row instead of single
GUILD_IMPLEMENTER_AGENT_ID/GUILD_WORKER_VAULT_ID env vars (those seed default row).
Reject: per-conversation config switching (requires Fountain changes). Consequence:
workers table this slice; env vars become seed values for the default row.
## decisions/0013-multi-repo-deployment.md (rewrite stub as Accepted)
Decision: one Guild deployment, repos config table (full_name, enabled, worker_id).
Webhook routes event by repo to configured worker(s). Reject: k8s-per-repo (ops
expensive). Consequence: repos table this slice; no k8s or webhook changes yet.
## Schema + migrations (3 migrations, no behavior change)
1. create table(:workers): worker_id string pk, fountain_agent_id string, vault_id
   string, github_installation_id string nullable, timestamps.
2. create table(:repos): full_name string unique, enabled boolean default true,
   worker_id string, timestamps.
3. alter table(:threads): add owner string nullable.
Seed in priv/repo/seeds.exs or a data migration: insert default worker row from env
(GUILD_IMPLEMENTER_AGENT_ID, GUILD_WORKER_VAULT_ID) and repos row ("jhgaylor/guild").
Ecto schemas: Guild.Schema.Worker, Guild.Schema.Repo. Thread schema: add :owner field.
mix test --exclude e2e green. PR open on g4/slice-6a-multiworker-adrs-schema.
