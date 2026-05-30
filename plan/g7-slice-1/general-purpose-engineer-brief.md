# G7 Slice 1 — Multi-Repo Live-Fire (Engineering Only)

Repo: jhgaylor/guild. Branch: g7/slice-1-multi-repo.
Operator-dependent steps (Jake picks second repo, installs App, creates issue) are
NOT in this PR — they happen post-merge. Engineering work only.
TESTS REQUIRED. Do NOT create scratch docs outside plan/g7-slice-1/.
## 1. lib/guild/release.ex — Guild.Release.add_repo/3
Read how migrate/0 and seed/0 are implemented (Ecto.Migrator.with_repo pattern).
Add: add_repo(full_name, worker_id \\ "default", enabled \\ true) that:
  - Calls load_app() + uses Ecto.Migrator.with_repo(Guild.Repo, fn _repo -> ... end)
    so it works in bin/guild eval without the full supervision tree.
  - Upserts via Guild.Schema.Repo changeset + Guild.Repo.insert with
    on_conflict: :nothing, conflict_target: :full_name. Idempotent.
  - Logger.info the result (inserted or already-exists).
Callable as: bin/guild eval 'Guild.Release.add_repo("owner/name")'
## 2. test/guild_web/controllers/webhook_controller_test.exs — routing smoke test
Add a two-repos routing test: seed a "default" worker row and an "alt" worker row
(Guild.Schema.Worker.changeset), seed two repos rows (repo-a with worker_id
"default", repo-b with worker_id "alt"). Send a synthetic issues.opened webhook
for repo-a: assert the enqueued Oban ClaimWorker job args have worker_id "default".
Send one for repo-b: assert worker_id "alt". Use Oban :inline test mode.
Read the existing webhook_controller_test.exs setup patterns before writing.
## 3. docs/add-repo.md — operator runbook
Write a short runbook covering:
  Step 1: (Optional) add a Guild.Schema.Worker row for the second repo if a
    different worker is needed — most setups skip this (default worker covers all).
  Step 2: add the repos row via:
    kubectl exec deploy/guild -n guild -- /app/bin/guild eval \
      'Guild.Release.add_repo("owner/name")'
  Step 3: install the Guild GitHub App on the second repo at
    github.com/apps/<your-app>/installations (GitHub App settings).
  Step 4: create a bot-ready issue on the second repo; watch /threads in the
    Guild UI for the claim, PR, and :done transition.
  Troubleshooting subsection:
    - Webhook for unconfigured repo: Guild logs a warning and returns 200 no-op.
    - Webhook never arrives for a repo where the App is not installed — GitHub
      simply does not send it. Install the App first.
## Done-when
mix test --exclude e2e green (including new two-repos routing test).
Guild.Release.add_repo callable via bin/guild eval in a release context.
docs/add-repo.md committed. PR open on g7/slice-1-multi-repo.
