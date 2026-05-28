# G4 Slice 1 — Race Fix, UI Auth, SECRET_KEY_BASE

Repo: jhgaylor/guild. Branch: g4/slice-1-race-fix-auth-secrets.
## lib/guild/claiming.ex
claim_issue/2: wrap check-existing → upsert → claim in Repo.transaction/1.
Inside tx call SELECT pg_try_advisory_xact_lock($1) with thread.id via
Ecto.Adapters.SQL.query!(Repo, "SELECT pg_try_advisory_xact_lock($1)", [thread.id]).
Result row value false → return {:error, :already_claimed} and abort. No change
to public API signature.
## lib/guild_web/router.ex
Add pipeline :auth (plug Plug.BasicAuth, username: System.get_env("OPERATOR_USERNAME"),
password: System.get_env("OPERATOR_PASSWORD")). Apply :auth before all browser
routes (/threads, /threads/:id, /decisions).
## lib/guild_web/endpoint.ex
Remove secret_key_base hardcoded literal. Replace with:
secret_key_base: System.fetch_env!("SECRET_KEY_BASE").
## Dockerfile
Remove openssl rand fallback from entrypoint that generates SECRET_KEY_BASE at boot.
SECRET_KEY_BASE must be supplied by environment; startup fails if absent.
## k8s/secret.yaml
Add SECRET_KEY_BASE, OPERATOR_USERNAME, OPERATOR_PASSWORD keys (placeholder base64).
Comment: live cluster Secret needs these keys provisioned out-of-band (Infisical/kubectl).
## Tests + Done-when
Two concurrent Task.async claim_issue/2 calls same issue: assert exactly one {:ok, _}
and one {:error, :already_claimed}. GET /threads without credentials: assert 401.
Missing SECRET_KEY_BASE at startup: assert fails fast. mix test --exclude e2e green.
PR open on g4/slice-1-race-fix-auth-secrets.
