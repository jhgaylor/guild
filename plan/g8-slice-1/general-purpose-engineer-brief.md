# G8 Slice 1 — Landing Page + /admin Shell + Integration Status Dashboard

Repo: jhgaylor/guild. Branch: g8/slice-1-admin-shell.
TESTS REQUIRED. Read existing controllers/templates before editing.
Do NOT create scratch docs outside plan/g8-slice-1/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs. If rebar3 missing: mix local.rebar --force.

## 1. Enhanced home page — lib/guild_web/controllers/page_html/home.html.heex
Public route (no auth). Replace current minimal page with:
- Hero heading + punchy copy: "Guild watches your repos for bot-ready issues, claims them,
  and ships PRs — steered from Slack, observed in here"
- Short feature list (3-5 bullets): repo claiming, Slack control plane, durable Oban queue,
  multi-repo support, observable thread timeline. Each bullet anchors to the relevant UI:
  /threads, /jobs, /admin where appropriate.
- "Try it on your repo" CTA linking to /docs/setup.md (or docs/setup.md relative path).
Keep markup semantic — plain HTML, no decorative noise.

## 2. /admin shell — lib/guild_web/controllers/admin_controller.ex (NEW)
New controller with actions:
- index/2 -> renders /admin landing page with card-style sub-navigation to:
  /admin/repos, /admin/workers, /admin/integrations
- repos/2 -> placeholder: "Repos management coming in Slice 2"
- workers/2 -> placeholder: "Workers management coming in Slice 3"
- integrations/2 -> integration status dashboard (see section 3)

Templates: lib/guild_web/controllers/admin_html/ (NEW directory)
- index.html.heex — /admin landing with 3 nav cards
- repos.html.heex — placeholder text
- workers.html.heex — placeholder text
- integrations.html.heex — 4 integration status cards

Router (lib/guild_web/router.ex): add inside the existing scope that has pipe_through [:browser, :auth]:
  scope "/admin", GuildWeb do
    get "/", AdminController, :index
    get "/repos", AdminController, :repos
    get "/workers", AdminController, :workers
    get "/integrations", AdminController, :integrations
  end

## 3. Integration status — GET /admin/integrations
Each integration gets a private helper integration_status/1 returning
{:ready | :unconfigured | :failing, details_map}.

Read env presence via Application.get_env(:guild, KEY) — use these exact atom keys found in the codebase:

GitHub App:
- NOTE: GitHub App credentials are read via System.get_env/1 directly in Guild.GitHub.HttpAdapter
  (not via Application.get_env). Check System.get_env("GITHUB_APP_ID"),
  System.get_env("GITHUB_PRIVATE_KEY"), System.get_env("GITHUB_INSTALLATION_ID").
- Also check Application.get_env(:guild, :github_webhook_secret) as a secondary signal (set in runtime.exs for non-test envs).

Slack (all via Application.get_env(:guild, KEY)):
- :slack_signing_secret
- :slack_bot_token  (read via Application.get_env(:guild, :slack_bot_token) in Guild.Adapters.Slack)
- :slack_channel_id (read via Application.get_env(:guild, :slack_channel_id) in Guild.Adapters.Slack)

Linear (all via Application.get_env(:guild, KEY)):
- :linear_api_key
- :linear_team_id
- :linear_state_in_progress_id
- :linear_state_done_id

Fountain (all via Application.get_env(:guild, KEY)):
- :fountain_api_key
- :fountain_base_url
- :guild_implementer_agent_id

GitHub App card: ready iff System.get_env("GITHUB_APP_ID") + System.get_env("GITHUB_INSTALLATION_ID") + System.get_env("GITHUB_PRIVATE_KEY") all present (non-nil, non-empty).
Last webhook delivery = most recent Guild.Schema.Event where source == "github" (display GuildWeb.Format.time_ago/1; "no events yet" if nil).

Slack card: ready iff Application.get_env(:guild, :slack_signing_secret) + Application.get_env(:guild, :slack_bot_token) + Application.get_env(:guild, :slack_channel_id) all present.
If only :slack_signing_secret set: "inbound ready, outbound unconfigured".
Last outbound = most recent Guild.Schema.Artifact where artifact_type == "slack_message".

Linear card: ready iff Application.get_env(:guild, :linear_api_key) + Application.get_env(:guild, :linear_team_id) present.
Secondary signal: show whether :linear_state_in_progress_id and :linear_state_done_id are set.
Last outbound = most recent Guild.Schema.Thread where linear_issue_id IS NOT NULL (ordered by updated_at desc).
(Linear outbound does NOT use artifacts — it stores linear_issue_id on threads.)

Fountain card: ready iff Application.get_env(:guild, :fountain_api_key) + Application.get_env(:guild, :fountain_base_url) + Application.get_env(:guild, :guild_implementer_agent_id) present.
NO live API probe on page render. Show "configured" or "unconfigured" only.

## 4. Tests
test/guild_web/controllers/admin_controller_test.exs (NEW):
- GET / returns 200, body contains hero copy phrase "watches your repos", "Try it on your repo" link, links to /threads, /jobs, /admin
- GET /admin without auth returns 401
- GET /admin with valid basic auth returns 200 + sub-nav links to /admin/repos, /admin/workers, /admin/integrations
- GET /admin/integrations with auth returns 200; renders all four cards
- Test: with Application.put_env setting GitHub keys -> card shows "ready"; without -> "unconfigured". Clean up with on_exit.
- Same put_env pattern for Slack and Linear cards.
- Fountain card shows "unconfigured" when keys absent.

Run mix test --exclude e2e and confirm green before opening the PR.
