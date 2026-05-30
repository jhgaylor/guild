# Operator Runbook: Adding a Second Repository

This guide walks through connecting a new GitHub repository to Guild so it can
receive webhooks, claim `bot-ready` issues, and dispatch work to a Fountain agent.

---

## Step 1 — (Optional) Add a Worker row for the second repo

Most deployments skip this step. The `default` worker handles all repos unless you
need the second repo to use a different Fountain agent or vault.

If you do need a separate worker:

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval \
  'Guild.Repo.insert!(%Guild.Schema.Worker{
    worker_id: "alt",
    fountain_agent_id: "your-agent-id",
    vault_id: "your-vault-id"
  }, on_conflict: :nothing, conflict_target: :worker_id)'
```

---

## Step 2 — Add the repos row

Register the new repository with Guild. The command is idempotent — safe to run
more than once.

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval \
  'Guild.Release.add_repo("owner/name")'
```

To route the repo to a non-default worker (created in Step 1):

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval \
  'Guild.Release.add_repo("owner/name", "alt")'
```

Signature: `Guild.Release.add_repo(full_name, worker_id \\ "default", enabled \\ true)`

---

## Step 3 — Install the Guild GitHub App on the second repo

Open your GitHub App's installation settings and grant access to the new repository:

```
https://github.com/apps/<your-app>/installations
```

GitHub will not send webhooks for a repository where the App is not installed.

---

## Step 4 — Verify with a bot-ready issue

1. Open a new issue on the second repository.
2. Add the `bot-ready` label.
3. Watch `/threads` in the Guild UI — you should see the thread appear, transition
   through `claiming → executing`, and a PR open shortly after.

---

## Troubleshooting

### Webhook arrives but no thread is created

- **Unconfigured repo** — Guild logs a warning and returns `200 no-op`. Confirm the
  repos row exists: check your database or re-run `add_repo`.
- **Repo is disabled** — `enabled: false` in the repos row silently drops the
  webhook. Update the row or re-run `add_repo` with `enabled: true`.

### Webhook never arrives

GitHub does not send webhooks for repositories where the App is not installed. Verify
the installation in your GitHub App settings (Step 3) before investigating further.

### Wrong worker is picked up

Confirm the `worker_id` on the repos row matches an existing workers row. Guild falls
back to environment-variable credentials when the worker row is missing, which may
produce unexpected behaviour.
