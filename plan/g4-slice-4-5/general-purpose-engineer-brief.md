# G4 Slices 4+5 — Slack + Linear Adapters

Repo: jhgaylor/guild. Branch: g4/slice-4-5-adapters.
Two adapters, two commits, one PR. Use HTTPoison/Hackney + Jason (already in deps).
GUARDRAIL: do NOT add compile:true/override:true hacks or rebar3 workarounds to
mix.exs. If rebar3 is missing run 'mix local.rebar --force'. Repo must build clean.
## COMMIT 1 — Guild.Adapters.Slack (Slice 4)
lib/guild/adapters/slack.ex: post_message(channel, text) POSTs to Slack Web API
chat.postMessage with SLACK_BOT_TOKEN bearer auth and SLACK_CHANNEL_ID (or passed
channel). Graceful no-op ({:ok, :not_configured}) if SLACK_BOT_TOKEN or
SLACK_CHANNEL_ID absent. Wire into Guild.Reconcile: on :pr_open and :done transitions
call post_message with "Thread #N: :pr_open — <pr_link>" / "Thread #N: :done". Also
route Guild.Primitives.Communication.post_to_channel/2 + reply_in_thread/3 through
the adapter (replacing {:error,:permanent,:not_configured} stubs) if those stubs exist.
k8s/secret.yaml: add SLACK_BOT_TOKEN, SLACK_CHANNEL_ID (placeholder base64, operator
comment: provisioned out-of-band). test/guild/adapters/slack_test.exs: Bypass mock;
assert chat.postMessage payload (channel, text fields); assert no-op when env absent.
## COMMIT 2 — Guild.Adapters.Linear (Slice 5)
lib/guild/adapters/linear.ex: create_issue(attrs) and update_issue(id, attrs) via
Linear GraphQL API (https://api.linear.app/graphql); reads LINEAR_API_KEY + LINEAR_TEAM_ID
from env; graceful no-op if absent. Wire: create Linear issue on thread :claimed (in
Guild.Claiming.claim_issue/2 after success); update to In Progress on :executing;
update to Done on :done (in Guild.Reconcile). k8s/secret.yaml: add LINEAR_API_KEY,
LINEAR_TEAM_ID (placeholder base64). test/guild/adapters/linear_test.exs: Bypass mock;
assert GraphQL mutation payload shape; assert no-op when env absent.
## Done-when
mix test --exclude e2e green. PR open on g4/slice-4-5-adapters.
