# G9 Slice 3 — Operator Slack Setup Runbook + Sanity-Check Tool

Repo: jhgaylor/guild. Branch: g9/slice-3-slack-setup.
DOCUMENTATION + one release function. No LiveView/controller changes.
Do NOT create scratch docs outside plan/g9-slice-3/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

---

## 1. docs/slack-setup.md (NEW)

Mirror structure and tone of docs/add-repo.md: numbered steps with `---` separators,
operator-focused prose, bash code blocks for any shell commands, a Troubleshooting
section at the end.

Eight steps:

---

### Step 1 — Create a Slack App

Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App → From
scratch**. One App per Guild instance — do not share across forks.

Suggested name: "Guild — <your-org>".

---

### Step 2 — Bot Token Scopes

Under **OAuth & Permissions → Bot Token Scopes**, add:

- `chat:write` — post messages to channels
- `reactions:read` — observe reactions for stop_sign hold control

---

### Step 3 — Event Subscriptions

Enable the **Events API**. Set **Request URL** to:

```
https://<your-deploy-host>/slack/events
```

(e.g. `https://guild.inevitable.fyi/slack/events`)

Subscribe to Bot Events:

- `message.channels` — replies in public channels the bot is in
- `reaction_added` — reactions on any message in channels the bot is in

Slack will challenge the URL when you save. Guild handles `url_verification` (verified in
G6 Slice 3). The challenge should pass on the first save.

---

### Step 4 — Install App to workspace

Click **Install to Workspace**. After installation, note:

- **Bot OAuth Token** (starts with `xoxb-`) — from the OAuth & Permissions page
- **Signing Secret** (32 lowercase hex chars) — from the Basic Information page

---

### Step 5 — Add bot to the target channel

In Slack: open the channel (e.g. `#guild`), type `/invite @<your-bot-name>`.

Note the **Channel ID** (not the name): open channel details → scroll to bottom → copy
the member ID (starts with `C`).

---

### Step 6 — Provision secrets in the live k8s Secret

Add three keys to the cluster Secret:

- `SLACK_BOT_TOKEN` — the `xoxb-...` token from Step 4
- `SLACK_CHANNEL_ID` — the `C...` channel ID from Step 5
- `SLACK_SIGNING_SECRET` — the signing secret from Step 4

Example (kubectl patch approach):

```bash
kubectl patch secret guild-app-secrets -n guild \
  --type='json' \
  -p='[{"op":"add","path":"/data/SLACK_BOT_TOKEN","value":"<base64-encoded-token>"},
       {"op":"add","path":"/data/SLACK_CHANNEL_ID","value":"<base64-encoded-id>"},
       {"op":"add","path":"/data/SLACK_SIGNING_SECRET","value":"<base64-encoded-secret>"}]'
```

---

### Step 7 — Roll the deployment

```bash
kubectl rollout restart deployment/guild -n guild
```

Wait for rollout:

```bash
kubectl rollout status deployment/guild -n guild
```

---

### Step 8 — Verify with sanity-check

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval 'Guild.Release.slack_ping()'
```

Expected output: prints `Slack ping succeeded.` and returns `:ok`. A "Slack ping from
Guild" message should appear in the channel.

Then visit `/admin/integrations` — the Slack card should show ✓ ready.

---

## Troubleshooting

### "URL not verified" in Slack App Event Subscriptions

Confirm `guild.inevitable.fyi/slack/events` is reachable. A `curl -X POST` to that URL
without a valid signature should return `403` (not `404` or connection refused). If `404`,
check the router — the route must be `POST /slack/events`.

### slack_ping returns :ok but no message appears

Confirm the bot is invited to the channel identified by `SLACK_CHANNEL_ID`. The bot must
be a member to post. Run `/invite @<your-bot-name>` in the target channel.

### slack_ping returns :error

Most common cause is a stale env var. Confirm the rollout completed
(`kubectl rollout status`) before running the ping. Check that `SLACK_BOT_TOKEN` starts
with `xoxb-`.

### slack_ping prints "Slack not configured"

`SLACK_BOT_TOKEN` or `SLACK_CHANNEL_ID` is missing from the Secret. Re-check Step 6 and
re-roll the deployment (Step 7).

---

## 2. Guild.Release.slack_ping/0 — lib/guild/release.ex

Add alongside `migrate/0`, `seed/0`, `add_repo/3`. Mirror the `load_app()` call pattern
(call `load_app()` at the top, then do work).

The Slack adapter signature (from lib/guild/adapters/slack.ex) is:

```elixir
def post_message(channel \\ nil, text, opts \\ []) :: {:ok, :not_configured} | {:ok, map()} | {:error, atom(), term()}
```

When `channel` is `nil`, `post_message` falls back to `SLACK_CHANNEL_ID`. The
unconfigured no-op returns `{:ok, :not_configured}` — handle it explicitly so operators
get a clear message rather than a misleading `:ok`.

Implementation:

```elixir
def slack_ping do
  load_app()

  message = "Slack ping from Guild — if you see this, the bot is live."

  case Guild.Adapters.Slack.post_message(message, []) do
    {:ok, :not_configured} ->
      IO.puts("Slack not configured (SLACK_BOT_TOKEN or SLACK_CHANNEL_ID missing).")
      :error

    {:ok, _} ->
      IO.puts("Slack ping succeeded.")
      :ok

    {:error, _tier, reason} ->
      IO.puts("Slack ping failed: #{inspect(reason)}")
      :error

    other ->
      IO.puts("Slack ping unexpected response: #{inspect(other)}")
      :error
  end
end
```

Note: `post_message/2` is the two-argument form `post_message(text, opts)` where
`channel` defaults to `nil` (and the adapter falls back to `SLACK_CHANNEL_ID`). Check
the function head carefully — `post_message(channel \\ nil, text, opts \\ [])` means
calling `post_message(message, [])` passes `message` as `channel` and `[]` as `text`.
**Call it as `post_message(nil, message, [])` to be explicit**, or check existing callers
in `lib/guild/reconcile.ex` to see which arity they use.

---

## 3. docs/setup.md

Find the `SLACK_BOT_TOKEN` entry in Step 5 (the Optional keys table). After the closing
table, before the `---` separator that starts Step 6, add exactly one line:

```
For Slack integration setup (App creation, event subscriptions wiring), see [docs/slack-setup.md](slack-setup.md).
```

---

## 4. Tests — test/guild/release_test.exs (CREATE — file is absent)

Use Bypass to mock the Slack `chat.postMessage` endpoint. Follow the Bypass pattern used
in other adapter tests in the repo (e.g. `test/guild/adapters/`).

Two tests for `slack_ping/0`:

**Test 1 — success path**

Bypass returns `{"ok": true, "channel": "C123", "ts": "111.222"}`.
Assert `Guild.Release.slack_ping()` returns `:ok`.

Setup:
```elixir
Application.put_env(:guild, :slack_bot_token, "xoxb-test")
Application.put_env(:guild, :slack_channel_id, "C123")
Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/chat.postMessage")
```
Clean up with `on_exit`.

**Test 2 — error path**

Bypass returns `{"ok": false, "error": "not_in_channel"}`.
Assert `Guild.Release.slack_ping()` returns `:error`.

Same setup pattern.

**Test 3 — unconfigured path (optional but recommended)**

No `slack_bot_token` or `slack_channel_id` in env.
Assert `Guild.Release.slack_ping()` returns `:error` (prints "Slack not configured").

Module skeleton:

```elixir
defmodule Guild.ReleaseTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()
    # Store original values
    orig_token = Application.get_env(:guild, :slack_bot_token)
    orig_channel = Application.get_env(:guild, :slack_channel_id)
    orig_url = Application.get_env(:guild, :slack_api_url)

    Application.put_env(:guild, :slack_bot_token, "xoxb-test")
    Application.put_env(:guild, :slack_channel_id, "C123")
    Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/chat.postMessage")

    on_exit(fn ->
      restore_env(:guild, :slack_bot_token, orig_token)
      restore_env(:guild, :slack_channel_id, orig_channel)
      restore_env(:guild, :slack_api_url, orig_url)
    end)

    {:ok, bypass: bypass}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, val), do: Application.put_env(app, key, val)

  test "slack_ping/0 returns :ok when Slack responds with ok: true", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "channel" => "C123", "ts" => "111.222"}))
    end)

    assert Guild.Release.slack_ping() == :ok
  end

  test "slack_ping/0 returns :error when Slack responds with ok: false", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "error" => "not_in_channel"}))
    end)

    assert Guild.Release.slack_ping() == :error
  end
end
```

Run `mix test --exclude e2e` — must be green before opening the PR.
