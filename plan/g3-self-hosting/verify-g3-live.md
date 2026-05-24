# G3 Live Verification Runbook

Operator steps to verify end-to-end self-hosting after merging G3.

1. Confirm `guild.inevitable.fyi` is running: `curl -s https://guild.inevitable.fyi/` returns 200.
2. Confirm the GitHub webhook is configured in jhgaylor/guild Settings → Webhooks:
   - Payload URL: `https://guild.inevitable.fyi/api/webhooks/github`
   - Content type: `application/json`
   - Secret: matches `GITHUB_WEBHOOK_SECRET` env var in the k8s deployment
   - Events: Issues, Pull requests
3. Open a new issue on https://github.com/jhgaylor/guild with a clear task title.
4. Add the label `bot-ready` to the issue.
5. Watch https://guild.inevitable.fyi/threads — within ~10s a Thread row should appear.
6. Thread state transitions (refresh the page or watch logs):
   - `unnoticed` → `noticed` → `claimed` → `executing` (Fountain worker dispatched)
7. The Fountain worker opens a PR referencing `Closes #<issue>` in the PR body.
8. Guild.Reconcile fires within 30s: thread transitions `executing` → `pr_open`.
   - A `pull_request` artifact appears on the thread.
9. Merge the PR on GitHub.
   - GitHub sends `pull_request.closed` (merged=true) webhook.
   - Thread transitions `pr_open` → `done`.
10. Verify final state on /threads: thread state = `done`.
