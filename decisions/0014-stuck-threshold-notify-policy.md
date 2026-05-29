# ADR 0014 — Stuck-Thread Detection, Notification Policy, and Owner Release

**Status:** Accepted
**Date:** 2026-05-29

## Context

G4 live-fire exposed a trust gap: threads can stall silently in `:executing` or `:pr_open` indefinitely, with no signal to the operator until they run `kubectl exec ... bin/guild rpc`. G5 closes this by detecting stuck threads and alerting proactively via Slack. Additionally, G4 sets `threads.owner` at claim time but never clears it; stale ownership in terminal threads misrepresents the system state and could block future re-claiming logic.

This ADR establishes: (1) where stuck detection runs, (2) what thresholds define "stuck", (3) how alerts are sent and deduplicated, and (4) when `threads.owner` is released.

## Decision

**Detection — Pass C in Guild.Reconcile (not a separate job):**
Stuck detection runs as a new Pass C in the existing `Guild.Reconcile` GenServer, which already fires every 30 seconds alongside Pass A (`:executing`→`:pr_open`) and Pass B (`:pr_open`→`:done`). Keeping all scheduled inspection in one GenServer is consistent with the established pattern and avoids splitting scheduling concerns across multiple periodic processes.

**Thresholds (module constants):**
- A thread in `:executing` with `updated_at` older than **2 hours** is stuck.
- A thread in `:pr_open` with `updated_at` older than **48 hours** is stuck.

Age-in-state is derived from `threads.updated_at` as a pragmatic proxy. A dedicated `state_entered_at` column would be more precise but adds schema complexity without materially changing the alerting outcome at current Guild scale; `updated_at` is updated on every state transition and closely approximates state entry time. This is a known approximation, noted here for future revisit if false positives emerge.

Thresholds are module constants (`@executing_stuck_after_ms`, `@pr_open_stuck_after_ms`) rather than env/DB-configurable values. Making them configurable adds UI/config surface not yet needed; the constants are the right defaults and are easily changed in source.

**Notification — Slack via existing adapter, with deduplication:**
On detecting a stuck thread, Pass C calls `Guild.Adapters.Slack.post_message/2` with a message identifying the thread, its state, and how long it has been stuck. The Slack adapter is already wired in G4 and is a graceful no-op when `SLACK_BOT_TOKEN`/`SLACK_CHANNEL_ID` are absent.

Alert deduplication: Pass C checks `threads.last_alerted_at`. If the thread was alerted within a **6-hour cooldown window**, the alert is skipped. On sending an alert, `last_alerted_at` is updated. This prevents alert spam during extended stalls while re-alerting if a stall persists beyond the cooldown.

**Owner release — clear on terminal state:**
`threads.owner` is cleared (set nil) when a thread enters any terminal state (`:done`, `:abandoned`). Owner implies active work by a specific worker; leaving it set on a terminal thread is misleading and could block future re-claiming. This is the natural companion to stuck-detection and is included in this slice.

## Consequences

- New migration: add `last_alerted_at :utc_datetime, null: true` to threads table.
- `Guild.Reconcile` gains Pass C: query threads in (`:executing`, `:pr_open`) where `updated_at < now - threshold` and `last_alerted_at` is nil or older than 6h; post Slack alert; update `last_alerted_at`.
- State-transition logic clears `threads.owner` on `:done`/`:abandoned`.
- Threads index and detail view gain a stuck attention badge/banner computed from `updated_at` + state (implementation in Slice 2 code, not this ADR).
- `Guild.Schema.Thread` gains `last_alerted_at` field; changeset updated.
- No new secrets or k8s changes required.

## Alternatives considered

- **Separate periodic job (Oban Cron):** Rejected. The Reconcile GenServer already runs every 30 seconds and handles all scheduled thread inspection. A separate job would split scheduling concerns and add Oban queue config for a task logically part of reconciliation.
- **Env/DB-configurable thresholds:** Deferred. Module constants are the right default. Can be promoted to env vars or a config table in a later gate if operational needs change.
- **No alert deduplication:** Rejected. Without dedup, a thread stuck for 24 hours generates up to 2,880 alerts per day (one per 30s reconcile). Alert spam defeats proactive notification.
- **Dedicated `state_entered_at` column:** Deferred. `updated_at` is a close-enough proxy at current scale. Can be added if false positives from multi-field updates cause operational noise.
