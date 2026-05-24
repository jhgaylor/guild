# G3 Slice Plan — Self-hosting Cutover

**Goal:** Operator opens an issue on jhgaylor/guild, labels it `bot-ready`, and watches
in /threads as Guild ingests the webhook, creates a thread, claims it, dispatches a worker,
reconciles when the PR opens, and transitions on merge — all without operator intervention.

---

## Slice 1 — Webhook Ingestion + k8s Secrets

**Summary:** Wire POST /api/webhooks/github and add deploy secrets manifest.

**In-scope:**
- `lib/guild_web/controllers/webhook_controller.ex` — HMAC validation (GITHUB_WEBHOOK_SECRET),
  event normalization (issues.opened, issues.labeled, pull_request.opened, pull_request.merged,
  push), insert into Guild.Schema.Event, thread_id resolution via explicit-ref scan (ADR 0006:
  "Closes #N" / "Fixes #N" / "#N" in body). Unknown events → 200 no-op.
- `lib/guild_web/router.ex` — add `post "/api/webhooks/github", WebhookController, :receive`
  outside the browser scope (no CSRF).
- `k8s/secret.yaml` — Secret manifest with keys: GITHUB_APP_ID, GITHUB_PRIVATE_KEY,
  GITHUB_INSTALLATION_ID, GITHUB_WEBHOOK_SECRET, FOUNTAIN_BASE_URL, FOUNTAIN_API_KEY,
  GUILD_IMPLEMENTER_AGENT_ID, GUILD_WORKER_VAULT_ID (values are placeholders; operator fills
  via Infisical / kubectl).
- `k8s/deployment.yaml` — add envFrom: secretRef pointing to the secret.
- Tests: HMAC valid → 200 + Event row inserted; HMAC invalid → 403; unknown event → 200 no-op.

**Stays stubbed:** No claiming logic — events land in DB only.

**Acceptance:** POST /api/webhooks/github with a valid signature inserts an Event row and returns 200.

**Dependencies:** None.

**Brief estimate:** 28 lines.

---

## Slice 2 — Live Claiming from Webhooks

**Summary:** Extract ClaimSeed logic into a library function; webhook handler auto-claims on
`bot-ready` label; thread vault_id wired.

**In-scope:**
- `lib/guild/claiming.ex` — `Guild.Claiming.claim_issue/2(repo, issue_number)` encapsulates the
  7-step ClaimSeed sequence (upsert thread, transition :unnoticed→:noticed→:claimed, insert seed
  event, dispatch Fountain conversation). Vault_id read from `Application.get_env(:guild,
  :worker_vault_id)` (GUILD_WORKER_VAULT_ID env var). assign_to_self omitted (GitHub Apps
  cannot be assignees — accepted limitation per G3 spec).
- `mix/tasks/guild.claim_seed.ex` — delegate to `Guild.Claiming.claim_issue/2`.
- `lib/guild_web/controllers/webhook_controller.ex` — on issues.opened or issues.labeled event:
  if label list includes "bot-ready", call `Guild.Claiming.claim_issue/2` asynchronously (Task.start).
- `config/runtime.exs` — read GUILD_WORKER_VAULT_ID.
- Tests: Guild.Claiming unit tests with TestAdapter; webhook controller test for bot-ready label
  path (assert thread created + :claimed).

**Stays stubbed:** Reconciliation, merge handling.

**Acceptance:** Posting a webhook payload for an issue labeled `bot-ready` creates a Thread in
:claimed state and a Fountain artifact.

**Dependencies:** Slice 1.

**Brief estimate:** 28 lines.

---

## Slice 3 — Guild.Reconcile GenServer

**Summary:** Move reconciliation from E2E test TODO into a supervised GenServer.

**In-scope:**
- `lib/guild/reconcile.ex` — `Guild.Reconcile` GenServer. 30s poll via
  `:timer.send_interval(30_000, self(), :reconcile)`. `handle_info(:reconcile)` finds threads in
  :executing with a fountain_conversation artifact, calls `Guild.Adapters.Fountain.get_status/1`,
  when :idle calls `Guild.GitHub.impl().list_pull_requests/2`, inserts pull_request Artifact,
  transitions thread :executing → :pr_open via StateMachine + Repo.update.
- `lib/guild/application.ex` — add Guild.Reconcile to supervision tree.
- `test/guild/e2e/contribute_md_test.exs` — remove Step 3.5 manual reconciliation; replace with
  direct `Guild.Reconcile.reconcile_thread/1` call (or let the GenServer handle it if timing allows).
- Tests: unit tests with mocked Fountain (idle + running states) and TestAdapter GitHub; assert
  pull_request artifact inserted and thread transitions to :pr_open.

**Stays stubbed:** pull_request.merged → :done transition (next slice or post-G3).

**Acceptance:** Thread in :executing with fountain_conversation artifact transitions to :pr_open
within two poll cycles when Fountain is idle and a matching PR exists.

**Dependencies:** Slice 2.

**Brief estimate:** 28 lines.

---

## Slice 4 — Integration Test + ROADMAP Close

**Summary:** End-to-end smoke test via webhook payloads; ROADMAP updated to close G3.

**In-scope:**
- `test/guild/integration/webhook_to_pr_test.exs` — `@moduletag :integration`. Seeds a fake
  GitHub issue payload → POST /api/webhooks/github (with valid HMAC) → assert Thread :claimed →
  simulate Fountain idle (via TestAdapter) → call Guild.Reconcile.reconcile_all/0 → assert
  Thread :pr_open + pull_request Artifact. No live Fountain or GitHub calls.
- `ROADMAP.md` — G3 Now → Done; add G4 Gated section (placeholder).

**Stays stubbed:** Live Fountain/GitHub in integration test (uses adapters).

**Acceptance:** Integration test passes without live external calls. Smoke path from webhook
ingestion to :pr_open in a single test run. ROADMAP reflects G3 closed.

**Dependencies:** Slices 1-3.

**Brief estimate:** 20 lines.
