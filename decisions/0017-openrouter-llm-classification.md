# ADR 0017 — OpenRouter for Stateless LLM Classification

**Status:** Accepted
**Deciders:** captain-picard (proposed), driver (accepted 2026-05-31)
**Context:** G10 — Guild listens in Slack and acts like a colleague

---

## Context

G10 introduces semantic engagement: Guild reads top-level Slack messages and
decides `:new_work | :refers_to_existing | :noise` via an LLM classifier. This
requires calling an LLM API on each qualifying message.

Two implementation paths exist:

**Option A — Fountain conversation per classification.** Spawn a Fountain conv,
get the verdict, terminate. Fountain handles agent boot, vault load, conv
lifecycle, and Pass D termination.

**Option B — OpenRouter direct.** Call the OpenRouter API directly from a
`Guild.LLM.OpenRouter` module. One HTTP POST, structured JSON response.

Additionally, once we call OpenRouter, we must decide: which model, what happens
when OpenRouter is down, and how to record this as a durable architectural
principle rather than a one-off.

---

## Decision

**Use OpenRouter direct (Option B) for stateless one-shot LLM work. Record
the Fountain/OpenRouter boundary as a first-class architectural principle.**

### The Fountain vs. OpenRouter line

| Use Fountain | Use OpenRouter direct |
|---|---|
| Stateful multi-turn agent work | Stateless one-shot LLM calls |
| Needs tools (GitHub, Slack, Linear) | No tools — prompt in, JSON out |
| Needs vault credentials (per-worker identity) | Global API key sufficient |
| Conv lifecycle + Pass D termination matter | No lifecycle — ephemeral request/response |
| Minutes-to-hours execution time | Sub-second to a few seconds |
| Examples: claim an issue, implement a PR | Examples: classify a message, extract entities, summarize text |

Classification is stateless, single-turn, and has no tool calls. Spawning a
full Fountain conversation (agent boot, ETS pools, vault load, supervisor
registration, Pass D) adds 5–15s of overhead to a 0.5–2s LLM call. At
100 classifications/day, that overhead is tolerable; at 1000/day with many
channels, it is not. OpenRouter gives model flexibility without lifecycle weight.

### Model choice

**Default: `openai/gpt-4o-mini` via OpenRouter.**

Rationale:
- Proven performance on classification + structured JSON output tasks.
- ~$0.15 per 1M input tokens + $0.60 per 1M output tokens (as of 2026-05).
- At ~600 tokens per classification (prompt + completion), cost ≈ $0.0004 per
  classification — $0.04 per 100 msgs, $1.50/day at 100 msgs/day after prefilter.
- OpenRouter exposes other models behind the same API. Upgrading is a one-line
  env-var change: `OPENROUTER_CLASSIFIER_MODEL=anthropic/claude-3-haiku`.

Alternatives considered:
- `meta-llama/llama-3.1-8b-instruct` — cheaper but rate-limited on free tier;
  JSON reliability lower for structured output.
- `anthropic/claude-3-haiku` — excellent quality, ~3× cost; reserve as upgrade path.
- Local model (Ollama) — no cloud dependency, but requires GPU in the k8s cluster.
  Not viable for standard Guild deployments.

### Structured JSON output schema

The classifier prompt instructs the model to return exactly this JSON (no
markdown fences, no commentary):

```json
{
  "verdict": "new_work",
  "confidence": 0.92,
  "reasoning": "The message 'can you fix the typo in README?' is a direct request to perform a repository task.",
  "matched_thread_id": null
}
```

Fields:
- `verdict`: one of `"new_work"` | `"refers_to_existing"` | `"noise"`. Required.
- `confidence`: float 0.0–1.0. Required. The model's self-assessed certainty.
- `reasoning`: string ≤ 500 chars. Required. Shown in `/admin/slack-inbox` for
  operator review. Must be in the prompt — LLMs omit it when not instructed.
- `matched_thread_id`: string UUID or `null`. For `refers_to_existing`: the
  thread the classifier matched from the candidate list. For `new_work`: null at
  classification time; populated later (see `thread_id` in `slack_inbox_events`)
  when ClaimWorker creates the work thread. The classifier selects from the
  candidate thread list included in the prompt.

The `slack_inbox_events` table stores `thread_id` (not `matched_thread_id`) and
dual-purposes the column: for `:refers_to_existing` it is set immediately on
classification; for `:new_work` it is null until the GitHub issue is created and
the webhook creates a work thread — at which point the thread-creation path
looks up the `slack_inbox_events` row by `github_issue_url` and backfills
`thread_id`, then inserts an `Event` row (`source: "slack"`, `event_type:
"slack.message"`) on the new thread so the originating Slack message appears in
the thread timeline on `/threads/:id`.

The classifier prompt includes `"Return only valid JSON. No markdown. No
commentary before or after the JSON object."` The parser validates with
`Jason.decode/1` + pattern match on required keys; malformed → treat as
`:noise` with `confidence: 0.0` and record the raw response in `reasoning`.

### Confidence threshold

**Global default: 0.7.** Configurable via `SLACK_INBOX_CONFIDENCE_THRESHOLD`
env var (float, parsed at startup). Below threshold: record Event, no action.
Per-channel thresholds deferred to G11.

### Rate limiting

**1 classification per (user_id, channel_id) per 60 seconds.** Enforced inside
`SlackInboxWorker` at the start of `perform/1`, before the OpenRouter call.
Implementation: query `slack_inbox_events` for a row with matching `(channel_id,
user_id)` inserted in the last 60 seconds. If found, return `:ok` silently (no
new row, no action). Enforcing inside the worker (rather than at the Events
handler before enqueue) keeps the Events handler thin and ensures rate-limit
state survives across pod restarts without ETS.

### Failure modes

| Failure | Handling |
|---|---|
| OpenRouter unreachable / timeout (>10s) | Job fails; Oban retries once with 30s backoff. After 2 attempts, record `status: :failed` Event row, no side effect. |
| HTTP 4xx from OpenRouter (bad key etc.) | Record `status: :failed` Event with error, no retry (4xx is not transient). |
| Malformed / non-JSON response | Treat as `:noise`, `confidence: 0.0`, record raw response in `reasoning`. |
| `OPENROUTER_API_KEY` absent | Inbox disabled entirely; SlackInboxWorker is never enqueued. Integration status dashboard shows OpenRouter card as ⚠ unconfigured. |
| OpenRouter returns valid JSON but wrong shape | Same as malformed — `:noise`, `confidence: 0.0`. |
| `SLACK_BOT_USER_ID` absent | Self-loop guard degrades to subtype-only (`subtype == "bot_message"`). Belt reduced to one strap until `SLACK_BOT_USER_ID` is provisioned. Log a warning at startup when absent so the operator notices. |

No cost cap in G10 v1. Expected cost at typical single-team usage (~50 qualifying
msgs/day after prefilter) is under $1/month. Document cost expectations in
`docs/slack-setup.md` addendum; add cost-cap mechanism (daily spend ceiling →
auto-flip to dry-run) as a G11 candidate if multi-channel deployments surface
the need.

### Dry-run mode

`SLACK_INBOX_DRY_RUN` env var, default `"true"`. When true: classifier still
runs, Event row is recorded with full reasoning, but no GitHub issue is created
and no Slack reply is posted. Operator reviews `/admin/slack-inbox` to validate
classifier quality before flipping to `"false"`. The transition is one env-var
change + rollout — no code change required.

---

## Consequences

**Positive:**
- Sub-second classification latency (no Fountain conv overhead).
- Model is swappable via env var with no deploy required.
- Clear Fountain/OpenRouter boundary prevents future architectural drift.
- Dry-run default enables safe rollout to production channels.

**Negative:**
- New runtime dependency: `OPENROUTER_API_KEY`. Inbox silently disabled when
  absent rather than crashing; integration status surface makes this visible.
- One more HTTP client in the supervision tree (`Guild.LLM.OpenRouter` uses
  HTTPoison, same as the Slack adapter — no new dep).
- OpenRouter as a third-party intermediary; outages block classification. The
  fail-safe is record-and-skip, not block-and-error.

---

## Alternatives not chosen

**Option A — Fountain per classification.** Rejected: ~15s overhead vs. ~1s,
vault load unnecessary, Pass D termination overhead, complicates observability
(classification results live in Fountain conv history, not Guild DB).

**No LLM — rule-based classifier.** Rejected: keyword matching produces too
many false positives/negatives for the "acts like a colleague" bar. LLM
judgment on natural language is the right tool here.
