# Operator Runbook: Wiring Slack to Guild

This guide walks through connecting a Slack workspace to Guild so it can post
messages to a channel, receive slash commands, and process button interactions and
reactions. Complete all eight steps in order.

**One App per Guild instance.** Do not share a Slack App across multiple Guild
forks — each instance needs its own App for clean credential isolation.

---

## Step 1 — Create a Slack App

Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App**.
Choose **From scratch**. Give it a recognizable name like `Guild — <your-org>`.
Select your workspace and click **Create App**.

---

## Step 2 — Add Bot Token Scopes

In the left sidebar, go to **OAuth & Permissions**. Scroll to **Bot Token Scopes**
and add the following scopes:

| Scope | Why |
|---|---|
| `chat:write` | Post messages and reply to threads |
| `reactions:read` | Observe reactions (`:stop_sign` → hold a thread) |

---

## Step 3 — Configure Event Subscriptions

In the left sidebar, go to **Event Subscriptions**. Toggle **Enable Events** on.

Set the **Request URL** to your Guild deployment's events endpoint:

```
https://<your-deploy-host>/slack/events
```

For example: `https://guild.inevitable.fyi/slack/events`

Slack will immediately challenge the URL. Guild handles `url_verification` correctly
(wired in G6 Slice 3), so the challenge passes on the first save.

Under **Subscribe to Bot Events**, add:

| Event | Why |
|---|---|
| `message.channels` | Capture replies in public channels the bot is in |
| `reaction_added` | Route stop_sign reactions to Guild.Control.hold |

Click **Save Changes**.

---

## Step 4 — Install the App to Your Workspace

In the left sidebar, go to **OAuth & Permissions**. Click **Install to Workspace**.
Authorize the requested permissions.

After installation, copy two values from the OAuth & Permissions page and from
**Basic Information**:

- **Bot OAuth Token** — starts with `xoxb-` (from OAuth & Permissions → OAuth Tokens)
- **Signing Secret** — 32 lowercase hex characters (from Basic Information → App Credentials)

---

## Step 5 — Invite the Bot to the Target Channel

In Slack, open the channel you want Guild to post to (e.g. `#guild`). Type:

```
/invite @<your-bot-name>
```

The bot must be a member of the channel to post messages.

Next, find the **Channel ID** (not the display name — Guild uses the ID):

1. Open the channel in Slack.
2. Click the channel name at the top to open channel details.
3. Scroll to the bottom of the details panel.
4. Copy the **Member ID** — it starts with `C` (e.g. `C08ABCDEF12`).

---

## Step 6 — Provision Secrets in the Live Cluster

Add the three Slack keys to the cluster Secret. The `kubectl patch` approach is
idempotent — safe to run against an existing secret:

```bash
SLACK_BOT_TOKEN_B64=$(echo -n "xoxb-..." | base64)
SLACK_CHANNEL_ID_B64=$(echo -n "C08ABCDEF12" | base64)
SLACK_SIGNING_SECRET_B64=$(echo -n "<32-hex-chars>" | base64)

kubectl patch secret guild-app-secrets -n guild \
  --type='json' \
  -p="[
    {\"op\":\"add\",\"path\":\"/data/SLACK_BOT_TOKEN\",\"value\":\"${SLACK_BOT_TOKEN_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/SLACK_CHANNEL_ID\",\"value\":\"${SLACK_CHANNEL_ID_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/SLACK_SIGNING_SECRET\",\"value\":\"${SLACK_SIGNING_SECRET_B64}\"}
  ]"
```

---

## Step 7 — Roll the Deployment

Restart the Guild pod so it picks up the new env vars:

```bash
kubectl rollout restart deployment/guild -n guild
kubectl rollout status deployment/guild -n guild
```

Wait for the rollout to complete before proceeding.

---

## Step 8 — Verify with the Sanity-Check Tool

Run the built-in ping to confirm Guild can post to the channel:

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild eval 'Guild.Release.slack_ping()'
```

Expected output: `Slack ping succeeded.` A message **"Slack ping from Guild — if you
see this, the bot is live."** should appear in the configured channel.

Then visit `/admin/integrations` in the Guild UI — the Slack card should show **✓ ready**.

---

## Troubleshooting

### "URL not verified" in Slack App Event Subscriptions

Confirm your deploy host is publicly reachable. A POST to the events endpoint without
a valid signing secret should return `403`, not `404` or a connection timeout:

```bash
curl -v -X POST https://<your-deploy-host>/slack/events
# Expect: HTTP 403 (fail-secure — missing signature)
# If you get 404: check the router has /slack/events wired
# If you get connection refused: the host is unreachable from Slack's servers
```

### `slack_ping` returns `:ok` but no message appears in Slack

The most common cause: the bot is not a member of the channel identified by
`SLACK_CHANNEL_ID`. Confirm the bot was invited (Step 5) and that `SLACK_CHANNEL_ID`
is the **Channel ID** (starts with `C`), not the display name.

### `slack_ping` returns an error tuple

Most common cause: stale env vars. Confirm the rollout completed before running the ping:

```bash
kubectl rollout status deployment/guild -n guild
```

Then re-run the ping. Also check that `SLACK_BOT_TOKEN` starts with `xoxb-` — a
corrupted or expired token is the second most common cause.

### Slash commands or interactive buttons not working

`/guild` slash commands and interactive buttons require `SLACK_SIGNING_SECRET`. Confirm
it is set and matches the value from Slack's **Basic Information → App Credentials** page.
The signing secret is used to verify every inbound Slack request; a mismatch returns `403`.
