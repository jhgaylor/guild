# G3 Slice 1 — Webhook Ingestion + k8s Secrets

Repo: jhgaylor/guild. Branch: g3/slice-1-webhook-ingestion.
## webhook_controller.ex
receive/2: read raw body; HMAC-SHA256 with GITHUB_WEBHOOK_SECRET via :crypto.hash_equals;
403 on mismatch/missing X-Hub-Signature-256. Parse JSON; switch on X-GitHub-Event:
issues.opened, issues.labeled, pull_request.opened, pull_request.merged, push → insert
Guild.Schema.Event. Unknown events → 200 no-op. Thread_id: scan body["body"] for
~r/(Closes|Fixes) #(\d+)/i (ADR 0006 explicit-only); null if no match.

## cache_body_reader.ex + endpoint.ex
CacheBodyReader stores raw body in conn private. Add body_reader: {CacheBodyReader,
:read_body, []} to Plug.Parsers in endpoint.ex so HMAC runs after JSON parsing.

## router.ex
Pipeline :webhook (plug :accepts, ["json"]). Scope "/api": post "/webhooks/github",
WebhookController, :receive. Outside browser scope (no CSRF).

## k8s
secret.yaml — Secret guild-app-secrets: GITHUB_APP_ID, GITHUB_PRIVATE_KEY,
GITHUB_INSTALLATION_ID, GITHUB_WEBHOOK_SECRET, FOUNTAIN_BASE_URL, FOUNTAIN_API_KEY,
GUILD_IMPLEMENTER_AGENT_ID, GUILD_WORKER_VAULT_ID. Placeholder base64 values.
Comment: operator fills via Infisical/kubectl out-of-band.
deployment.yaml — envFrom: [{secretRef: {name: guild-app-secrets}}].
kustomization.yaml — include secret.yaml.

## Tests + Done-when
Valid HMAC + issues.opened → 200 + Event row. Invalid HMAC → 403. Missing header → 403.
Unknown event → 200 no-op. Closes #N in body → Event.thread_id set.
mix test --exclude e2e green. PR open on g3/slice-1-webhook-ingestion.
