# G7 Slice 3 — Demo Runbook + Onboarding Refresh

Repo: jhgaylor/guild. Branch: g7/slice-3-docs.
DOCUMENTATION ONLY. No code changes. No mix.exs/Dockerfile edits.
Do NOT create scratch docs outside plan/g7-slice-3/.
Pull content from existing PREREQUISITES.md and CONTRIBUTING.md where accurate; note anything outdated in the PR body.

## 1. docs/demo.md
Create this file. It has three sections:

### A. Try-it preamble (3-5 sentences)
A prospect reads this before the demo. Emphasize: Guild self-hosts on the prospect's own infra; no data leaves their environment; the setup path is docs/setup.md; the demo below runs live against a real repo.

### B. 5-Minute Demo (numbered walkthrough)
An operator follows this in real time during a customer demo.
- Para 1: What Guild is (one paragraph at top)
- Step 1: Open a bot-ready issue (label "bot-ready") on a configured repo
- Step 2: Watch /threads — show thread appearing and moving to :executing
- Step 3: Show /jobs (Oban queue) — ClaimWorker job processed
- Step 4: Show Slack interactive buttons (Hold / Abandon / View) in the Guild channel
- Step 5: Watch thread reach :pr_open then :done
- Step 6: Close with one-liner: "Guild claimed the issue, spawned a Fountain AI engineer, merged the PR, and updated Linear — zero human intervention."

### C. 15-Minute Deep Dive
Same arc but pauses to explain mechanics. Reference actual ADR numbers and module names.
- Pause after Step 1: Oban ClaimWorker (lib/guild/workers/claim_worker.ex), unique args, :claims queue, advisory lock + CAS on threads.owner (ADR 0011: decisions/0011-claiming-arbitration.md)
- Pause after Step 2: Reconcile passes A (executing→pr_open via idle Fountain + matching PR), B (pr_open→done via merged webhook), C (stuck detection + Slack alert, ADR 0014), D (Fountain conv termination for terminal threads)
- Pause after Step 4: Slack control plane — /guild slash command, Block Kit interactive buttons (Hold/Abandon/View), stop_sign reaction → hold (ADR 0015: decisions/0015-inbound-slack-control.md; ADR 0016: decisions/0016-bidirectional-sync.md); threads.held orthogonal to state machine
- Pause after Step 5: retention (lib/guild/retention.ex keeps 200 decisions_log rows per thread, nulls context_snapshot on older), summarization (lib/guild/summarization.ex threshold 50 context_notes → POSTs to Fountain for summary), ADR-style decision log in decisions/

## 2. docs/setup.md
Create this file. Seven numbered steps for a fresh Guild deploy:

Step 1: Fork jhgaylor/guild on GitHub.

Step 2: CI auto-builds ghcr.io/<owner>/guild:latest on push to main via .github/workflows/build.yml. First push triggers first image.

Step 3: Create a GitHub App at github.com/settings/apps/new.
- Required permissions: Issues (read/write), Pull Requests (read/write), Contents (read/write), Metadata (read)
- Required webhook events: issues, pull_request, push
- Webhook URL: https://<your-deploy-host>/api/webhooks/github
- Generate and download the App private key (PEM format).
- Note the App ID.

Step 4: Install the App on the first target repo. Note the Installation ID.

Step 5: Provision the live Secret in the cluster (reference k8s/secret.yaml for key list).
Critical keys: SECRET_KEY_BASE, OPERATOR_USERNAME, OPERATOR_PASSWORD, FOUNTAIN_API_KEY, FOUNTAIN_BASE_URL, GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_PRIVATE_KEY, GITHUB_WEBHOOK_SECRET, GUILD_IMPLEMENTER_AGENT_ID, GUILD_WORKER_VAULT_ID.
Optional (graceful no-ops when unset): SLACK_BOT_TOKEN, SLACK_CHANNEL_ID, SLACK_SIGNING_SECRET, LINEAR_API_KEY, LINEAR_TEAM_ID, LINEAR_STATE_IN_PROGRESS_ID, LINEAR_STATE_DONE_ID, LINEAR_WEBHOOK_SECRET.

Step 6: Deploy: kubectl apply -k k8s/
Note: k8s/secret.yaml is excluded from the kustomization — manage the live Secret out of band. The Dockerfile entrypoint runs Guild.Release.migrate() then Guild.Release.seed() automatically.

Step 7: Create the first bot-ready issue (label "bot-ready") on the configured repo and verify the full claim → PR → :done cycle from the /threads UI.

### Troubleshooting
- Thread not appearing: verify repo is registered (Guild.Release.add_repo/3), GitHub App installed on repo, GITHUB_APP_ID/INSTALLATION_ID correct.
- Thread stuck in :executing: check Fountain credentials (FOUNTAIN_API_KEY, FOUNTAIN_BASE_URL, GUILD_WORKER_VAULT_ID), check /jobs for failed ClaimWorker jobs.
- Missing Slack messages: verify SLACK_BOT_TOKEN and SLACK_CHANNEL_ID set.
- Additional repos: see docs/add-repo.md.

## 3. README.md
Add a "Try it on your repo" section near the top — after the one-sentence pitch, before Architecture/Contributing. Use 3-5 bullets summarizing setup path. Link to docs/setup.md as canonical guide. Reference docs/add-repo.md for adding additional repos.

## PR body notes
In the PR body, note anything you found in PREREQUISITES.md or CONTRIBUTING.md that is outdated (post-G4 deploy path, post-G5 Slack integration, post-G6 bidirectional sync) so the driver can decide on follow-up.
