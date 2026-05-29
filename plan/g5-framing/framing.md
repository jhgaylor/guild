# G5 — Framing

Framing for G5 produced at the close of G4. Captain-picard decomposes this
into a slice plan analogous to `plan/g4/slice-plan.md`; the driver reviews and
approves that slice plan before any slice is dispatched.

## Thesis

**Make Guild observable and steerable — so a human can run it, not just watch it.**

G4 made Guild safe and broad enough to run unattended. But "unattended" exposed
a trust gap: when the G4 live-fire stalled, the only way to see *what* Guild was
doing — thread state, the claim queue, why a thread was stuck — was to
`kubectl exec ... bin/guild rpc`. An operator can't run a system they can't see
into or steer. G5 closes that gap: every thread's live state and history visible
in the UI, stuck/failed work surfaced proactively, and the ability to intervene
(hold, abandon, re-run) from where the operator already is — Slack.

Builds on the existing G2.5 operator UI (`/threads` index, `/threads/:id`
LiveView, `/decisions`) and the G4 Slack/Oban work.

## Item inventory

### 1. Job & queue visibility (Oban Web)
Issue: G4 moved claiming onto Oban, but there's zero operator visibility into
the queue — in-flight, retrying, failed, or cancelled jobs are invisible without
DB access. Fix: mount Oban Web (or a minimal custom queue view) behind operator
auth at `/oban` (or `/jobs`). **Priority: high** — cheapest big win; the queue is
the heart of the system. Likely no ADR (Oban Web is a drop-in).

### 2. Thread timeline / richer detail view
Issue: `/threads/:id` shows thread basics but not the full story. Fix: a timeline
that interleaves events, decisions_log entries, context notes, artifacts (PR +
Fountain conv links), state-transition history, and current `owner`. Make the
thread's whole life legible at a glance. **Priority: high** — this is the primary
"what is Guild doing?" surface. No ADR.

### 3. Stuck / failed work surfacing
Issue: nothing flags a thread stuck in `executing` too long, a `pr_open` thread
whose PR isn't merging, or an Oban job that exhausted retries — exactly the
class of failure the G4 live-fire hit. Fix: a health/attention view (and badges
on the threads index) computed from thread age-in-state + Oban job state; plus a
Slack alert when something crosses a threshold. **Priority: high** — turns silent
stalls into visible ones. Possibly a small ADR for the threshold/notify policy.

### 4. Slack human-in-the-loop (inbound control)
Issue: the G4 Slack adapter is outbound-only (posts on pr_open/done). The
operator can't *steer* from Slack. Fix: inbound Slack (slash command or
interactive actions / Events API) mapped to thread actions — at minimum
`hold` / `resume` / `abandon` a thread, and optionally "approve before merge".
**Priority: medium-high** — the headline "steerable" capability. **Needs an ADR**:
inbound Slack surface (slash vs Events API vs interactive), the control
vocabulary, and how a control maps to thread state / worker conv.

### 5. `threads.owner` release semantics
Issue: G4 sets `owner` on claim but never clears it; stale ownership doesn't
reflect reality (terminal threads, restarted workers). Fix: clear `owner` on
terminal state and provide an operator "release/abandon" path. **Priority: medium**
— operational hygiene that underpins items 3 and 4. Small, ADR-light.

### 6. Worker-conversation lifecycle
Issue: worker convs stay `:running` indefinitely after opening their PR (benign
since reconcile no longer depends on idle, but they accumulate). Fix: a policy to
terminate/timeout worker convs once their thread reaches a terminal state, with
visibility into live worker convs. **Priority: low-medium**. Possibly folds into
item 5.

### 7. Notifications / operator digest *(stretch)*
Issue: no proactive "here's what happened" summary. Fix: a periodic Slack digest
(shipped / in-flight / stuck). **Priority: low** — could slip to G6.

## Suggested execution order

1. **G5 slice 1 — Oban Web + thread timeline.** The two highest-leverage
   read-only visibility wins; no ADRs. Make Guild legible first.
2. **G5 slice 2 — stuck/failed surfacing + owner-release.** Attention view +
   badges + Slack alert; clear `owner` on terminal state. Small ADR for the
   threshold/notify policy if needed.
3. **G5 slice 3 — Slack human-in-the-loop.** ADR first (inbound surface +
   control vocabulary), then implement hold/resume/abandon. The "steerable" core.
4. **G5 slice 4 — worker-conv lifecycle + (stretch) digest.** Cleanup +
   optional proactive summary; may defer to G6.

## Closing criteria

**G5 closes** when the operator can run Guild day-to-day without dropping to
`kubectl`: the UI shows every thread's live state, full history, and owner; the
Oban queue is visible; stuck/failed threads and jobs are surfaced proactively
(UI badge + Slack alert); and the operator can steer an in-flight thread from
Slack (at least hold / abandon). Verified live by observing a real thread's
lifecycle and steering one — entirely through the UI and Slack.

## Open architectural questions for the slice plan

- **Oban Web vs custom view (item 1):** Oban Web is a drop-in dep + route, but
  adds a dependency and its own assets. A minimal custom Ecto-query view avoids
  the dep. Pick before slice 1.
- **Inbound Slack surface (item 4):** slash command vs Events API vs interactive
  message actions — affects the Slack app config and the request-verification
  path. Pick before slice 3 (this is the slice's ADR).
- **Stuck thresholds (item 3):** fixed constants vs per-state config; where the
  detector runs (reconcile pass vs a separate periodic job).
- **Control → state mapping (item 4):** does "hold" pause the Oban job, signal
  the worker conv, or just set a thread flag reconcile respects? Needs to be
  decided alongside the inbound-Slack ADR.
