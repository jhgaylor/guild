# G4 Slice 2 — Durable Claim Queue (Oban)

Repo: jhgaylor/guild. Branch: g4/slice-2-durable-claim-queue.
ADR 0010 accepted Oban; implement per its consequences section.
## mix.exs + config
Add {:oban, "~> 2.18"} to deps. In config/config.exs add:
config :guild, Oban, repo: Guild.Repo, queues: [claims: 10].
In config/test.exs add: config :guild, Oban, testing: :inline.
Run mix oban.install to generate the oban_jobs migration.
## lib/guild/application.ex
Add {Oban, Application.fetch_env!(:guild, Oban)} to children list.
## lib/guild/workers/claim_worker.ex
use Oban.Worker, queue: :claims, unique: [fields: [:args], period: 60]
perform(%Job{args: %{"issue_number" => n, "repo" => r}}):
  call Guild.Claiming.claim_issue(n, r).
  {:ok, _} → {:ok, :claimed}. {:error, :already_claimed} → {:cancel, :already_claimed}.
  {:error, reason} → {:error, reason} (Oban retries with backoff).
## lib/guild_web/controllers/webhook_controller.ex
Replace Task.start fire-and-forget with:
  Guild.Workers.ClaimWorker.new(%{"issue_number" => n, "repo" => r}) |> Oban.insert!()
Return 200 immediately. Do NOT remove advisory lock in Guild.Claiming.
## test/guild/workers/claim_worker_test.exs
use Oban.Testing, repo: Guild.Repo. Three cases: (1) perform claim → {:ok, :claimed};
(2) already_claimed → {:cancel, :already_claimed}; (3) transient error → {:error, _}.
mix test --exclude e2e green. PR open on g4/slice-2-durable-claim-queue.
