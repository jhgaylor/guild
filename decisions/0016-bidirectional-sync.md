# ADR 0016 — Bidirectional Sync (Inbound Linear + Slack Events)

**Status:** Accepted
**Date:** 2026-05-30

## Context

G4 added outbound Slack and Linear adapters; G5 added inbound Slack slash commands and interactive buttons. Guild still has no inbound path from Linear or from Slack Events API. Operators cannot see Linear issue updates or Slack activity reflected in Guild, and cannot steer via Slack reactions. G6 Slice 3 closes this gap by ingesting inbound Linear webhooks and Slack Events, recording them as Guild Events, and mapping one selected Slack event to a state-driving action.

This ADR decides: (a) which inbound events to subscribe to and which drive state vs only-record; (b) how to correlate a Slack reaction to a Guild thread; (c) the verification model for both endpoints; (d) the route surface.

## Decision

**Linear inbound — record only, no state driving:**
Subscribe to Linear webhooks for Issue (state, title, description updates) and Comment events. Each verified inbound Linear event inserts a `Guild.Schema.Event` row with `event_type` prefixed `linear.` (e.g. `linear.issue_updated`, `linear.comment_created`) and the raw payload stored. No Linear event changes thread state.

Rationale: Guild thread state is anchored on GitHub (issues opened, PR merged). Linear is a secondary mirror. Driving state from Linear events would create feedback loops (Linear update → Guild state change → Linear update → Linear webhook → loop) and ambiguate the source of truth. Record-only gives full observability and audit trail without coupling.

**Slack Events API inbound — record all, one state-driving mapping:**
Subscribe to `reaction_added` and selected `message` events (scoped to channels where Guild posts, to avoid noise). Every verified inbound Slack event inserts an Event row with `event_type` prefixed `slack.` (e.g. `slack.reaction_added`, `slack.message`). The raw payload is stored.

The one state-driving mapping: a `stop_sign` reaction (Slack name `"stop_sign"`) added to a message Guild itself posted triggers `Guild.Control.hold/1` for the associated thread. This requires Guild to record which Slack message corresponds to which thread — see slack_message artifact below.

**`slack_message` artifact type:**
When Pass A (pr_open) and Pass B (done) successfully call `Guild.Adapters.Slack.post_message/3`, parse the Slack API response (`chat.postMessage` returns `channel` and `ts`) and record an Artifact with `artifact_type: "slack_message"`, `source: "slack"`, `external_id: ts` (the message timestamp, which Slack uses as a unique message identifier), and `url: "slack://#{channel}/#{ts}"` (encodes the channel without a new column). On a `slack.reaction_added` event whose `item.channel` and `item.ts` match a `slack_message` artifact, look up `artifact.thread_id` and call `Guild.Control.hold/1`.

The `url` field on Artifact already exists in the schema. Encoding `"slack://channel/ts"` in `url` avoids a migration and is sufficient for the lookup. This choice is noted; a dedicated `slack_channel` column can be added later if needed for richer querying.

**Verification — fail-secure on both:**
- *Linear:* Linear sends a `Linear-Signature` header containing HMAC-SHA256 of the raw body using `LINEAR_WEBHOOK_SECRET`. Reject with 403 if the header is missing, the signature does not match, or `LINEAR_WEBHOOK_SECRET` is absent. Reuse `CacheBodyReader` for raw-body capture.
- *Slack Events:* Same v0 HMAC scheme and `SLACK_SIGNING_SECRET` used by `/slack/commands` and `/slack/interactions`. Reuse the shared `verify_slack_request/1` helper introduced in G6 Slice 2. Handle Slack URL verification: when the request body has `"type": "url_verification"`, respond 200 with plain-text `challenge` value (required for initial Events API subscription; no HMAC verification needed for this specific type per Slack docs — but still reject malformed bodies).

**Routes (implementation in Slice 3; surface decided here):**
- `POST /linear/webhooks` — new `GuildWeb.LinearController`, outside `:auth` pipeline, raw-body via `CacheBodyReader`.
- `POST /slack/events` — new `events/2` action on existing `GuildWeb.SlackController`, outside `:auth`, raw-body via `CacheBodyReader`.

## Consequences

- New `GuildWeb.LinearController` with `POST /linear/webhooks` route.
- New `events/2` action on `GuildWeb.SlackController` with `POST /slack/events` route.
- `Guild.Adapters.Slack.post_message/3` return value captured; `slack_message` Artifact created on successful post.
- `reaction_added` stop_sign on a `slack_message` artifact → `Guild.Control.hold/1`.
- `k8s/secret.yaml`: add `LINEAR_WEBHOOK_SECRET` (placeholder base64; operator comment: configure the Linear webhook URL in the Linear team settings and Slack Events subscription in the Slack app manifest out-of-band).
- No new schema migration if `url` field encodes `slack://channel/ts`; one small migration if a dedicated `slack_channel` column is chosen — implementation decides.
- All Linear events record-only; no thread state changes from Linear.

## Alternatives considered

- **Drive state from Linear events (e.g. Linear issue closed → thread :done):** Rejected. Linear is a mirror of GitHub state; driving state from Linear creates feedback cycles and ambiguates the source of truth. Guild state must anchor on GitHub events.
- **Subscribe to all Slack message events for state-driving (e.g. any channel message → parse for intent):** Rejected. Channel message event volume is high and hard to scope safely. The stop_sign reaction on Guild-owned messages is a precise, low-noise trigger.
- **Use Slack interactive buttons only for control (no Events API):** Already implemented in G6 Slice 2. The Events API complements buttons — it lets operators use reactions instead of clicking, and is required for cases where the original message has no buttons (e.g. older messages).
- **Encode Slack channel as a dedicated `slack_channel` column on Artifact:** Deferred. The `url` field encoding `"slack://channel/ts"` is sufficient for the lookup query. A dedicated column can be added if richer channel-scoped querying is needed in a later gate.
