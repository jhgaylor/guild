# Operator Runbook: Wiring Slack to Guild

This guide walks through connecting a Slack workspace to Guild so it can post
messages to a channel, receive slash commands, and process button interactions and
reactions. Complete all eight steps in order.

**One App per Guild instance.** Do not share a Slack App across multiple Guild
forks — each instance needs its own App for clean credential isolation.

**Ordering matters.** Slack's Event Subscriptions URL verification calls Guild's
`/slack/events` endpoint the moment you save the Request URL, and the endpoint
rejects any request whose signature it can't verify. So Guild needs the
`SLACK_SIGNING_SECRET` live in its environment **before** you wire the Event
Subscriptions URL. The steps below provision secrets first, then turn on events.

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

## Step 3 — Install the App to Your Workspace

Still on **OAuth & Permissions**, click **Install to Workspace**. Authorize the
requested permissions. After installation, copy the **Bot OAuth Token** — it
starts with `xoxb-`. Keep it handy for Step 5.

---

## Step 4 — Invite the Bot to the Target Channel + Get Channel ID

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

Then grab the **Signing Secret**: in your Slack App's left sidebar, go to
**Basic Information → App Credentials** and copy the **Signing Secret** (32
lowercase hex characters).

You now have all three values: `xoxb-...` (Bot Token), `C...` (Channel ID),
and the signing secret.

---

## Step 5 — Provision Secrets in the Live Cluster

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

## Step 6 — Roll the Deployment

Restart the Guild pod so it picks up the new env vars:

```bash
kubectl rollout restart deployment/guild -n guild
kubectl rollout status deployment/guild -n guild
```

Wait for the rollout to complete before proceeding to Step 7.

---

## Step 7 — Configure Event Subscriptions

In your Slack App, go to **Event Subscriptions** and toggle **Enable Events** on.

Set the **Request URL** to your Guild deployment's events endpoint:

```
https://<your-deploy-host>/slack/events
```

For example: `https://guild.inevitable.fyi/slack/events`

Slack will immediately challenge the URL. Because Step 6 made `SLACK_SIGNING_SECRET`
live in Guild's environment, the challenge passes on the first save. If you see
"Your URL didn't respond with the value of the `challenge` parameter", confirm
the rollout completed and that the signing secret value matches Slack's Basic
Information → App Credentials page exactly.

Under **Subscribe to Bot Events**, add:

| Event | Why |
|---|---|
| `message.channels` | Capture replies in public channels the bot is in |
| `reaction_added` | Route stop_sign reactions to Guild.Control.hold |

Click **Save Changes**.

---

## Step 8 — Verify with the Sanity-Check Tool

Run the built-in ping to confirm Guild can post to the channel:

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild rpc 'Guild.Release.slack_ping()'
```

`rpc` runs the function inside the already-running BEAM node where Guild's
supervision tree (including the HTTP client's ETS pools) is up. `eval` starts
a fresh node that loads code but doesn't start supervisors — it will fail with
an ETS table error.

Expected output: `Slack ping succeeded.` A message **"Slack ping from Guild — if
you see this, the bot is live."** should appear in the configured channel.

Then visit `/admin/integrations` in the Guild UI — the Slack card should show **✓ ready**.

---

## Troubleshooting

### "Your URL didn't respond with the value of the `challenge` parameter" in Slack Event Subscriptions

Almost always means `SLACK_SIGNING_SECRET` isn't live in Guild's environment yet
(or doesn't match what Slack signs with). Check:

1. `kubectl get secret guild-app-secrets -n guild -o jsonpath='{.data.SLACK_SIGNING_SECRET}' | base64 -d` matches the value on Slack's **Basic Information → App Credentials** page.
2. The pod has been rolled since the secret was patched (`kubectl rollout status deployment/guild -n guild`).

A POST to the events endpoint without a valid signature should return `403`, not
`404` or a connection timeout:

```bash
curl -v -X POST https://<your-deploy-host>/slack/events
# Expect: HTTP 403 (fail-secure — missing signature)
# If you get 404: check the router has /slack/events wired
# If you get connection refused: the host is unreachable from Slack's servers
```

### `slack_ping` fails with `ArgumentError: the table identifier does not refer to an existing ETS table`

You used `eval` instead of `rpc`. `eval` starts a new BEAM node that loads code
but doesn't start the supervision tree, so the HTTP client's named ETS pools
don't exist. Switch to `rpc`:

```bash
kubectl exec deploy/guild -n guild -- /app/bin/guild rpc 'Guild.Release.slack_ping()'
```

### `slack_ping` returns `:ok` but no message appears in Slack

The most common cause: the bot is not a member of the channel identified by
`SLACK_CHANNEL_ID`. Confirm the bot was invited (Step 4) and that `SLACK_CHANNEL_ID`
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

---

## Activating the Slack Inbox (G10)

After Steps 1–8 are in place (Guild posting + reacting in Slack), the G10 inbox
adds *listening*: Guild reads top-level messages in enabled channels and decides
whether each is `:new_work`, `:refers_to_existing`, or `:noise` via an LLM
classifier (ADR 0017). Default rollout is **dry-run** — Guild records every
classification with reasoning on `/admin/slack-inbox` but takes no Slack/GitHub
action until you flip the flag off.

### Inbox Step A — Get the Bot User ID

The self-loop guard needs Guild's own bot user ID so it doesn't classify its own
posts. Find it via the Slack API:

```bash
curl -s -H "Authorization: Bearer xoxb-..." https://slack.com/api/auth.test | jq -r .user_id
```

The value starts with `U` (e.g. `U08XYZ123`). Save it for Step B.

### Inbox Step B — Provision Inbox Env Vars

Add the five inbox keys to the cluster Secret. Same idempotent `kubectl patch`
pattern as Step 5:

```bash
OPENROUTER_API_KEY_B64=$(echo -n "sk-or-..." | base64)
SLACK_BOT_USER_ID_B64=$(echo -n "U08XYZ123" | base64)
SLACK_INBOX_DRY_RUN_B64=$(echo -n "true" | base64)
SLACK_INBOX_CONFIDENCE_THRESHOLD_B64=$(echo -n "0.7" | base64)
OPENROUTER_CLASSIFIER_MODEL_B64=$(echo -n "openai/gpt-4o-mini" | base64)

kubectl patch secret guild-app-secrets -n guild \
  --type='json' \
  -p="[
    {\"op\":\"add\",\"path\":\"/data/OPENROUTER_API_KEY\",\"value\":\"${OPENROUTER_API_KEY_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/SLACK_BOT_USER_ID\",\"value\":\"${SLACK_BOT_USER_ID_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/SLACK_INBOX_DRY_RUN\",\"value\":\"${SLACK_INBOX_DRY_RUN_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/SLACK_INBOX_CONFIDENCE_THRESHOLD\",\"value\":\"${SLACK_INBOX_CONFIDENCE_THRESHOLD_B64}\"},
    {\"op\":\"add\",\"path\":\"/data/OPENROUTER_CLASSIFIER_MODEL\",\"value\":\"${OPENROUTER_CLASSIFIER_MODEL_B64}\"}
  ]"
```

Get an OpenRouter API key at [openrouter.ai/keys](https://openrouter.ai/keys).
Expected cost: <$1/month at single-team usage on `gpt-4o-mini` (ADR 0017).

### Inbox Step C — Roll the Deployment

```bash
kubectl rollout restart deployment/guild -n guild
kubectl rollout status deployment/guild -n guild
```

Visit `/admin/integrations` — the OpenRouter card should show **✓ ready**.

### Inbox Step D — Enable a Channel

In the Guild UI, go to **`/admin/slack-channels`** and add the channel:

- **Channel ID**: the same `C...` ID from Step 4
- **Default Repo**: the GitHub repo where `:new_work` issues should be filed
  (the bot must be configured for this repo via `/admin/repos`)
- Save with **enabled: true**

### Inbox Step E — Dry-Run Validation Period

Recommended: ≥3 days, or until you trust the classifier.

Post these in the configured Slack channel and check `/admin/slack-inbox` for
the classification + reasoning:

| Post | Expected verdict |
|---|---|
| "can you add a CHANGELOG entry for last week's release?" | `new_work`, confidence > 0.7 |
| "did that typo fix ship?" (with a matching open thread) | `refers_to_existing` matching the thread |
| "good morning everyone" | `noise` |
| (Guild's own `:done` reply or confirmation post) | **No row** — self-loop guard fired |

If a classification is wrong, use the **File as new work** or **Mark as noise**
override on `/admin/slack-inbox`. The override fires immediately regardless of
the dry-run flag.

Adjust `SLACK_INBOX_CONFIDENCE_THRESHOLD` in the Secret if classifications are
too aggressive (raise it) or too timid (lower it).

### Inbox Step F — Go Live

When dry-run validation feels right, flip the flag:

```bash
SLACK_INBOX_DRY_RUN_B64=$(echo -n "false" | base64)
kubectl patch secret guild-app-secrets -n guild \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/SLACK_INBOX_DRY_RUN\",\"value\":\"${SLACK_INBOX_DRY_RUN_B64}\"}]"
kubectl rollout restart deployment/guild -n guild
```

Live-fire test:
- Post a clear new-work request → expect a GitHub issue (with `bot-ready` label)
  + a threaded confirmation reply in Slack + the originating message visible as
  the first Event on `/threads/<new_thread_id>`.
- Post a reference → expect an `Open in Slack` reply + the message appearing on
  the referenced thread's timeline.
- Post noise → no Slack reply, no GitHub issue, but classification recorded.

### Inbox troubleshooting

| Symptom | Likely cause |
|---|---|
| `/admin/slack-inbox` empty after posting | Channel not in `/admin/slack-channels` or `enabled: false`. Check Slice 1 gate. |
| OpenRouter card shows ⚠ unconfigured | `OPENROUTER_API_KEY` not in the Secret or rollout pending. |
| Guild classifies its own messages (self-loop) | `SLACK_BOT_USER_ID` not set or wrong. Check Inbox Step A. |
| `:new_work` verdict but no GitHub issue filed | Confidence below threshold, OR channel has no `default_repo`. Check the row's `action_taken` and `reasoning`. |
| Same user spammed channel but only one classification | Working as designed — 1 classification per (user, channel) per 60s. |
