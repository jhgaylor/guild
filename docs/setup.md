# Guild Setup Guide

This guide walks through a fresh Guild deployment from fork to first successful `bot-ready` cycle. Complete all seven steps in order; each step's output is an input to the next.

---

## Step 1 — Fork the repo

Fork [jhgaylor/guild](https://github.com/jhgaylor/guild) to your GitHub account or organization. Clone your fork locally.

```bash
git clone https://github.com/<your-org>/guild.git
cd guild
```

All subsequent steps reference `<your-org>` as the GitHub owner of your fork.

---

## Step 2 — Let CI build the image

Guild ships a `.github/workflows/build.yml` workflow that builds and pushes `ghcr.io/<your-org>/guild:latest` on every push to `main`. The first push to `main` triggers the first image build — no manual Docker steps required.

Verify the image exists before continuing:

```bash
gh run list --workflow=build.yml --limit=5
```

Wait for the run to succeed, then confirm the package is visible at:

```
https://github.com/<your-org>/guild/pkgs/container/guild
```

---

## Step 3 — Create a GitHub App

Go to [github.com/settings/apps/new](https://github.com/settings/apps/new) and create a new GitHub App with the following configuration:

**Permissions (Repository):**
| Permission | Level |
|---|---|
| Issues | Read & write |
| Pull requests | Read & write |
| Contents | Read & write |
| Metadata | Read |

**Webhook events to subscribe:**
- `issues`
- `pull_request`
- `push`

**Webhook URL:**
```
https://<your-deploy-host>/api/webhooks/github
```

After saving:
1. Note the **App ID** shown on the App's settings page.
2. Scroll to the bottom and click **Generate a private key**. Download and keep the PEM file — you will need it in Step 5.
3. Generate a **Webhook secret** (any strong random string) and record it.

---

## Step 4 — Install the App on the target repo

Open your App's installation settings:

```
https://github.com/apps/<your-app-slug>/installations
```

Install it on the first repository you want Guild to monitor. After installation, the URL in your browser changes to include the **Installation ID** — record it:

```
https://github.com/organizations/<org>/settings/installations/<INSTALLATION_ID>
```

GitHub will not send webhooks for repositories where the App is not installed. See [docs/add-repo.md](add-repo.md) for adding additional repositories after the initial deploy.

---

## Step 5 — Provision the live cluster Secret

`k8s/secret.yaml` documents the full key set but is intentionally excluded from the kustomization (it is never applied via Flux). Create the real Secret out of band:

```bash
kubectl create secret generic guild-app-secrets -n guild \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --from-literal=OPERATOR_USERNAME="<admin-username>" \
  --from-literal=OPERATOR_PASSWORD="<strong-password>" \
  --from-literal=GITHUB_APP_ID="<App ID from Step 3>" \
  --from-literal=GITHUB_INSTALLATION_ID="<Installation ID from Step 4>" \
  --from-literal=GITHUB_PRIVATE_KEY="$(cat /path/to/private-key.pem)" \
  --from-literal=GITHUB_WEBHOOK_SECRET="<webhook secret from Step 3>" \
  --from-literal=FOUNTAIN_BASE_URL="https://fountain.inevitable.fyi" \
  --from-literal=FOUNTAIN_API_KEY="<your Fountain API key>" \
  --from-literal=GUILD_IMPLEMENTER_AGENT_ID="<Fountain agent ID>" \
  --from-literal=GUILD_WORKER_VAULT_ID="<Fountain vault ID>"
```

**Critical keys** — Guild will not start correctly without these:

| Key | Description |
|---|---|
| `SECRET_KEY_BASE` | Phoenix session signing key (64+ random bytes) |
| `OPERATOR_USERNAME` | Basic auth username for the Guild UI |
| `OPERATOR_PASSWORD` | Basic auth password for the Guild UI |
| `GITHUB_APP_ID` | Numeric App ID from Step 3 |
| `GITHUB_INSTALLATION_ID` | Numeric installation ID from Step 4 |
| `GITHUB_PRIVATE_KEY` | PEM private key downloaded in Step 3 |
| `GITHUB_WEBHOOK_SECRET` | Secret used to verify incoming webhook signatures |
| `FOUNTAIN_API_KEY` | API key from your Fountain workspace |
| `FOUNTAIN_BASE_URL` | Base URL of your Fountain instance |
| `GUILD_IMPLEMENTER_AGENT_ID` | ID of the Fountain agent that will implement issues |
| `GUILD_WORKER_VAULT_ID` | Fountain vault containing the agent's credentials |

**Optional keys** — Guild starts without these; the corresponding integrations silently no-op:

| Key | Integration |
|---|---|
| `SLACK_BOT_TOKEN` | Slack notifications and interactive controls |
| `SLACK_CHANNEL_ID` | Target Slack channel for Guild messages |
| `SLACK_SIGNING_SECRET` | Required for `/guild` slash commands and interactive buttons |
| `LINEAR_API_KEY` | Linear issue state transitions |
| `LINEAR_TEAM_ID` | Linear team to update |
| `LINEAR_STATE_IN_PROGRESS_ID` | UUID for the "In Progress" workflow state |
| `LINEAR_STATE_DONE_ID` | UUID for the "Done" workflow state |
| `LINEAR_WEBHOOK_SECRET` | Verifies inbound Linear webhooks |

---

## Step 6 — Deploy

Apply the Kubernetes manifests:

```bash
kubectl apply -k k8s/
```

`k8s/secret.yaml` is excluded from the kustomization — the `kubectl create secret` command in Step 5 handles it. Do not commit secrets to the repo.

The Dockerfile entrypoint automatically runs `Guild.Release.migrate/0` and `Guild.Release.seed/0` before starting the server, so the database schema and seed data are always current on startup.

Verify the pod is running:

```bash
kubectl get pods -n guild
kubectl logs deploy/guild -n guild --tail=50
```

Confirm the UI is reachable at `https://<your-deploy-host>/threads` — it will prompt for the `OPERATOR_USERNAME` / `OPERATOR_PASSWORD` you set in Step 5.

---

## Step 7 — Verify the full cycle

Register the repository with Guild:

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval \
  'Guild.Release.add_repo("<your-org>/<your-repo>")'
```

Then create the first bot-ready issue:

1. Open a new issue on the configured repository.
2. Apply the `bot-ready` label.
3. Watch `https://<your-deploy-host>/threads` — the thread should appear and advance through `:claiming` → `:executing`.
4. Check `https://<your-deploy-host>/jobs` — a processed `ClaimWorker` job confirms Guild dispatched the Fountain agent.
5. Wait for the Fountain agent to open a PR. The thread advances to `:pr_open`.
6. Merge the PR. The thread advances to `:done`.

A complete cycle from issue label to `:done` confirms your deployment is healthy.

---

## Troubleshooting

**Thread not appearing after labeling the issue.**
- Confirm the repository is registered: `Guild.Release.add_repo/3` is idempotent — re-run it and check the Guild logs for a confirmation message.
- Confirm the GitHub App is installed on the repository (Step 4). GitHub silently skips webhook delivery for uninstalled repos.
- Check `GITHUB_APP_ID` and `GITHUB_INSTALLATION_ID` match the values from Steps 3 and 4.

**Thread stuck in `:executing`.**
- Check Fountain credentials: `FOUNTAIN_API_KEY`, `FOUNTAIN_BASE_URL`, `GUILD_WORKER_VAULT_ID`.
- Open `https://<your-deploy-host>/jobs` and look for failed or retrying `ClaimWorker` jobs — the job error message will indicate whether the failure is a credential issue or a Fountain API error.

**No Slack messages appearing.**
- Confirm `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID` are set in the Secret.
- Confirm the bot has been invited to the target channel (`/invite @<bot-name>` in Slack).
- `/guild` slash commands and interactive buttons additionally require `SLACK_SIGNING_SECRET`.

**Adding more repositories.**
See [docs/add-repo.md](add-repo.md) for the full runbook on registering additional repositories, creating non-default workers, and installing the App on additional repos.
