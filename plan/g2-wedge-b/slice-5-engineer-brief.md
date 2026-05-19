# Slice 5 Engineer Brief — GitHub HttpAdapter + E2E Wiring

## Context
G2 Wedge B, Slice 5. Slices 1-4 merged. Base: main at 9da21e3.
ADRs 0002-0009 locked. Slice spec: plan/g2-wedge-b/slice-plan.md.
Fountain agent registered: guild-implementer (5442009b-5b31-4b2d-9868-fb6d1267b6c1)

## Task
- lib/guild/github/http_adapter.ex — @behaviour Guild.GitHub; all 15 callbacks;
  GitHub App auth (App ID+private key → JWT → installation token via
  /app/installations/{id}/access_tokens; cache+refresh); HTTPoison HTTP calls
- config/runtime.exs — wire HttpAdapter when MIX_ENV!=:test; env vars:
  GITHUB_APP_ID, GITHUB_PRIVATE_KEY, GITHUB_INSTALLATION_ID,
  FOUNTAIN_BASE_URL, FOUNTAIN_API_KEY, GUILD_IMPLEMENTER_AGENT_ID
- test/guild/e2e/contribute_md_test.exs @tag :e2e — run ClaimSeed for
  jhgaylor/guild#3; dispatch Fountain conv (agent_id from GUILD_IMPLEMENTER_AGENT_ID);
  poll until completed (30 min max); assert PR adds CONTRIBUTING.md;
  assert thread state=pr_open with pull_request artifact
- mix test --exclude e2e green; @tag :e2e excluded by default in test_helper.exs

## Acceptance
- HttpAdapter: all 15 callbacks unit-tested with Bypass
- mix test --exclude e2e green (all prior tests unaffected)
- E2E test compiles, is skippable, passes --include e2e with live creds
- config/runtime.exs reads exactly: GITHUB_APP_ID, GITHUB_PRIVATE_KEY,
  GITHUB_INSTALLATION_ID, FOUNTAIN_BASE_URL, FOUNTAIN_API_KEY,
  GUILD_IMPLEMENTER_AGENT_ID

## Out of scope
- Do NOT run mix test --include e2e (operator runs post-merge with prod .env)
- No LiveView controllers or UI changes
