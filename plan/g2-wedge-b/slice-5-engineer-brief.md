# Slice 5 Engineer Brief — GitHub HttpAdapter + E2E Wiring

## Context
G2 Wedge B, Slice 5. Slices 1-4 merged. Base: main at 9da21e3.
ADRs 0002-0009 locked. Slice spec: plan/g2-wedge-b/slice-plan.md.
Fountain agent: guild-implementer (5442009b-5b31-4b2d-9868-fb6d1267b6c1)

## Task
- http_adapter.ex — @behaviour Guild.GitHub; all callbacks; GitHub App auth
  (App ID+key → JWT → installation token; cache+refresh); HTTPoison
- config/runtime.exs — wire HttpAdapter when MIX_ENV!=:test; env vars:
  GITHUB_APP_ID, GITHUB_PRIVATE_KEY, GITHUB_INSTALLATION_ID,
  FOUNTAIN_BASE_URL, FOUNTAIN_API_KEY, GUILD_IMPLEMENTER_AGENT_ID
- contribute_md_test.exs @tag :e2e — ClaimSeed jhgaylor/guild#3; dispatch
  Fountain conv; poll 30 min; assert CONTRIBUTING.md PR; assert pr_open state

## Acceptance
- HttpAdapter: all callbacks unit-tested with Bypass; mix test --exclude e2e green
- E2E test compiles, skippable, passes --include e2e with live creds

## Out of scope
- Do NOT run mix test --include e2e (operator runs post-merge with prod .env)

## Post-merge amendments (g2/slice-5-e2e)
- Added `list_pull_requests/2` to Guild.GitHub behaviour, TestAdapter, and HttpAdapter
- Added Step 3.5 reconciliation to E2E test: queries open PRs, inserts
  pull_request artifact, transitions thread claimed→executing→pr_open
