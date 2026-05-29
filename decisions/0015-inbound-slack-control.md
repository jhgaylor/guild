# ADR 0015 — Inbound Slack Control (Human-in-the-Loop)

**Status:** Accepted
**Date:** 2026-05-29

## Context

G4 added outbound Slack notifications (`:pr_open`, `:done` events). G5 closes the steerable gap: the operator needs to intervene in in-flight threads from Slack without dropping to `kubectl`. The three operations required are hold (pause Guild automated progression), resume (restore), and abandon (terminate). This ADR decides the inbound surface, request verification, control vocabulary, and control→state mapping.

## Decision

**Inbound surface — slash command:**
A single `/guild` slash command with subcommands: `/guild hold <issue#>`, `/guild resume <issue#>`, `/guild abandon <issue#>`. The slash command is configured in the Slack app manifest; Slack POSTs to a Guild endpoint on invocation.

Rationale: the slash command is the simplest direct-control surface — one route, synchronous acknowledgement (200 + ephemeral response within 3s), no event subscriptions, no polling. It maps naturally to operator intent (explicit verb + target).

**Request verification — Slack v0 HMAC, fail-secure:**
Verify every inbound request using Slack's v0 signing scheme: compute `"v0=" <> hex(HMAC-SHA256(SLACK_SIGNING_SECRET, "v0:" <> timestamp <> ":" <> raw_body))` and constant-time compare to the `X-Slack-Signature` header. Also reject requests where `X-Slack-Request-Timestamp` is more than 5 minutes old (replay guard).

Fail-secure: if `SLACK_SIGNING_SECRET` is absent at startup or request time, reject all inbound requests (401/403). No unauthenticated control commands are accepted.

Raw body capture: reuse the same `CacheBodyReader` plug already used by the GitHub webhook controller — configure it on the `/slack/commands` endpoint so HMAC runs after JSON/form parsing.

**Control vocabulary + control→state mapping:**

`hold` and `held` are modelled as a boolean flag on threads (`threads.held`, default false) — orthogonal to the state machine. This keeps the state machine clean (`:executing`, `:pr_open`, etc. are unchanged) while allowing a held flag to suppress Guild's automated progression:
- **hold** (`/guild hold <issue#>`): set `threads.held = true`; cancel any pending Oban `ClaimWorker` job for the thread via `Oban.cancel_job`. Reconcile Pass A (`:executing`→`:pr_open` promotion) and Pass C (stuck alerts) skip held threads. The already-running Fountain worker conv cannot be paused externally — `hold` prevents Guild's automated progression, not the in-flight worker; this limitation is documented in the UI.
- **resume** (`/guild resume <issue#>`): set `threads.held = false`; reconcile resumes normal handling on the next pass.
- **abandon** (`/guild abandon <issue#>`): transition thread to `:abandoned` via `Meta.update_thread_state/2` (which clears `threads.owner` per ADR 0014); cancel any pending Oban job.

**Thread resolution:** commands resolve a thread by GitHub issue number (`anchor_type: :github_issue`, `anchor_id: issue_number`); optionally also accept a bare thread UUID. Issue number is operator-friendly and matches how operators naturally refer to work.

## Consequences

- New migration: add `held boolean, default: false, null: false` to threads table.
- `Guild.Schema.Thread`: add `field :held, :boolean, default: false`; update changeset.
- New `GuildWeb.SlackController` with `POST /slack/commands` route outside the `:auth` pipeline (Slack posts from the internet; auth is via signature verification). Raw-body capture via `CacheBodyReader`.
- New `Guild.Control` module: `hold/1`, `resume/1`, `abandon/1` each accepting an issue number or thread UUID.
- `Guild.Reconcile` Pass A and Pass C: add `where: not held` guard to queries.
- `k8s/secret.yaml`: add `SLACK_SIGNING_SECRET` (placeholder base64; operator comment: required for inbound Slack commands).
- Slack app manifest must add a `/guild` slash command pointing at `<base_url>/slack/commands` (operator configures out-of-band).
- Interactive message action buttons (richer UX) deferred to G6.

## Alternatives considered

- **Slack Events API:** Rejected for this slice. The Events API requires event subscriptions and asynchronous processing (Guild must POST back within 3s or use `response_url`). It is more appropriate for listening to ambient channel messages, not direct control commands. Can be adopted in G6 if richer conversational control is needed.
- **Interactive message action buttons:** Deferred to G6. Buttons require outbound messages to carry Slack Block Kit action blocks, which requires richer message templates and a separate `interactions` endpoint. Better UX but more implementation surface. The slash command delivers the same operator control with less complexity.
- **New state machine states (`:held`, `:abandoned` as explicit states):** Rejected for `held`. Adding `:held` as a state would complicate every state-machine transition and guard. A boolean flag orthogonal to the state machine achieves the same behavioral suppression cleanly. `:abandoned` remains a terminal state machine state (already exists or is added in Slice 3 implementation).
- **Address threads by internal UUID only:** Rejected. Operators think in terms of GitHub issue numbers; requiring a UUID lookup would force operators to cross-reference the Guild UI during a moment when they want to act quickly.
