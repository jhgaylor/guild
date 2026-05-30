# G7 Slice Plan

**Generated:** 2026-05-30
**Source:** plan/g7-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G7 closes when the driver judges Guild ready to demo to a real prospect on a second real repo. The slice plan is in service of that dry-run judgment, not a fixed item list. Ordering is high-leverage-first; the closing criterion lives in Slice 4.

**Architectural questions settled here:**
- **Same Guild instance for second repo:** G4 multi-repo design is one deployment serving N repos. Slice 1 adds the second repo row to the live instance — no second deployment.
- **Demo target audience:** technical founder evaluating Guild for their team (default until told otherwise). UI/docs emphasis is on clarity of the claim→PR→merge loop.
- **No ADRs required:** all decisions are operational (which repo, which runbook format) or UI-only.

---

## Slice 1 — Multi-Repo Live-Fire on a Second Real Repo

**Goal:** Prove the G4 multi-repo plumbing end-to-end against a real second repo. Close the gap between "Guild is wired for multi-repo" and "Guild ran on a second repo and shipped a PR there."

### In-scope (Guild-side engineering)

- `lib/guild/release.ex` — verify `seed/0` upserts correctly; confirm a second repos row can be added without a deploy.
- Simple operator-accessible path to add a repos row (`full_name`, `enabled`, `worker_id`) without a DB shell: a `mix guild.add_repo` Mix task runnable via `bin/guild rpc`, or a minimal protected LiveView admin page behind `:auth`. Pick the simpler option and note the choice in the PR.
- Routing smoke test: extend or add a test asserting that when two repos rows exist, a webhook for repo A enqueues with repo A worker_id and a webhook for repo B enqueues with repo B worker_id.
- `docs/add-repo.md` — short operator runbook: (1) add repos row, (2) install GitHub App on the repo, (3) create first `bot-ready` issue.

### Operator-dependent steps (Jake-only — not automatable by the engineer)

These steps cannot be completed by code and must be done by the driver before this slice closes:

1. **Pick the second repo.** A real Jake-owned repo with low-risk, bot-safe work (README polish, CHANGELOG, docs). Create at least one clearly-scoped `bot-ready` issue on it.
2. **Install the Guild GitHub App on the second repo.** The current installation covers only `jhgaylor/guild`; extend to the second repo in GitHub App settings.
3. **Add the second repo row** to the live Guild instance using the admin path from the engineering work.
4. **Watch the full cycle.** Create a `bot-ready` issue; confirm Guild claims it, opens a PR, and the thread reaches `:done` (or steerable state).
5. **Record evidence.** Note the thread URL, PR URL, and any friction in the ROADMAP or a brief ops note.

### Stubbed at this slice

- Multi-worker (multiple fountain_agent_id rows) — single worker serves both repos.
- Per-repo GitHub App installation automation.
- Full admin UI for managing repos/workers.

### ADRs required

None. Admin path choice (Mix task vs. LiveView) is documented inline.

### Acceptance criteria

- `mix test --exclude e2e` green, including the two-repos routing test.
- Operator can add a repos row without a DB shell.
- `docs/add-repo.md` committed.
- **Operator-dependent (Jake):** second repo row added; GitHub App installed; `bot-ready` issue claimed; PR opened on second repo.

### Depends on

G6 main. Driver picks the second repo before or during this slice.

### Estimate

~100 LOC (admin path + routing test) + `docs/add-repo.md`. Operator steps: Jake's call.

---

## Slice 2 — UI Polish for the Demo Screen

**Goal:** Make the operator UI tell the Guild story clearly enough that a prospect following along gets it. Three targeted improvements: home page, interleaved thread timeline (G6 Slice 4 deferred), and a "What just happened" strip.

### In-scope

- **Home page** (`lib/guild_web/live/home_live.ex` or root route): two-sentence description of Guild + prominent links to `/threads` and `/jobs`.
- **Interleaved chronological thread timeline** (`lib/guild_web/live/thread_live.ex` + `.html.heex`) — G6 Slice 4 deferred item. Merge Events, decisions_log entries, ContextNotes, and Artifacts into a single list sorted by `inserted_at`/timestamp. Render as one chronological feed. Add a "snapshot trimmed" visual marker on decisions_log entries where `context_snapshot` is nil (set by `Guild.Retention`).
- **"What just happened" strip** on `/threads` index: a small panel showing the last 5 state transitions across all threads (thread anchor_id, old state → new state, time ago). Query threads ordered by `state_entered_at` desc.
- Tests: home page renders description + nav links; `/threads/:id` renders merged timeline in chronological order; snapshot-trimmed marker present; strip shows recent transitions.

### Stubbed at this slice

- Pagination / virtual scrolling for long timelines.
- Real-time push updates to the strip.
- Rich marketing copy (two sentences is enough).

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Home page renders with Guild description and nav links.
- `/threads/:id` shows single merged chronological timeline with snapshot-trimmed marker.
- "What just happened" strip on `/threads` shows recent state transitions.

### Depends on

Slice 1 merged. Can run in parallel with Slice 3.

### Estimate

~200 LOC + tests. One engineer.

---

## Slice 3 — Demo Runbook + Onboarding Refresh

**Goal:** A prospect who sees the demo has a credible, documented path to try Guild on their own repo. A runbook prevents the demo from being fumbled.

### In-scope

- **`docs/demo.md`** — the demo script:
  - *5-minute version:* create `bot-ready` issue → Guild claims → Fountain agent opens PR → `:done` → Slack message with buttons.
  - *15-minute deep dive:* Oban queue, thread timeline, owner CAS, Reconcile passes, Slack control plane (`/guild hold`, interactive buttons, stop_sign reaction), `/jobs` dashboard.
  - *"Try it on your repo" preamble:* one paragraph for a prospect.
- **`docs/setup.md`** — operator setup runbook: fork repo; configure CI; create GitHub App + install on target repo; provision secrets (reference `k8s/secret.yaml` key list); deploy (reference k8s manifests); seed default worker + repo row; create first `bot-ready` issue.
- **README.md** — add "Try it on your repo" section (3–5 bullets) linking to `docs/setup.md` before the Contributing section.
- Pull content from existing `CONTRIBUTING.md` and `PREREQUISITES.md` where accurate; note where those docs are dated.

### Stubbed at this slice

- Hosted/managed Guild (SaaS) path — docs cover self-hosted only.
- Video walkthrough.
- Automated setup scripts.

### ADRs required

None.

### Acceptance criteria

- `docs/demo.md` committed with 5-min and 15-min script outlines.
- `docs/setup.md` committed covering all seven setup steps.
- README "Try it on your repo" section links to `docs/setup.md`.
- Driver read-through finds no obviously wrong steps.

### Depends on

Slice 1 merged (so add-repo step is accurate). Can run in parallel with Slice 2.

### Estimate

~800 words of documentation. One pass; driver read-through before merge.

---

## Slice 4 — Driver Dry-Run + Targeted Fixes

**Goal:** Run a real demo against the second-repo deployment, surface what is rough, fix what is cheap, and close G7 when the bar is met. Judgment-gated — the driver decides when done.

### Dry-run checklist (driver executes)

- **Golden path:** open `bot-ready` issue on second repo → Guild claims within 1 reconcile cycle → thread timeline shows claim → Fountain agent opens PR → `:pr_open` → Slack message with Hold/Abandon buttons → PR merged → `:done` → Slack done message → Fountain conv terminated (Pass D).
- **Control-plane:** `/guild hold <issue#>` pauses; `/guild resume` resumes; Hold button on `:pr_open` Slack message works.
- **Oban queue:** `/jobs` dashboard shows no stuck or failed jobs during golden path.
- **UI sanity:** home page legible; `/threads` strip shows transitions; thread detail timeline tells the story; nothing embarrassing.

### What to capture during the dry-run

- Wince-worthy moments (error copy, latency, confusing UI, missing info).
- Blocking defects (things that would stop a prospect cold).
- Quick-fix vs. G8-defer candidates.

### Fix scope

Blocking defects and wince-worthy moments that are ≤ 1–2 hours each. Defer larger items to G8. Document what was fixed and what was deferred in the ROADMAP G7 Done entry.

### Stubbed at this slice

- Systematic UX review beyond what the dry-run surfaces.
- Performance testing.
- Anything post-G7 (SaaS, billing, multi-tenant, hosted).

### ADRs required

None.

### Acceptance criteria

Driver judgment: "I would sit next to a prospect, open the second repo, create a `bot-ready` issue, and watch the full cycle — without wincing." Evidenced by the dry-run checklist completed and the deferred list recorded.

### Depends on

Slices 1, 2, and 3 merged.

### Estimate

Dry-run: 1–2 hours. Fixes: judgment-scoped (0–1 day). Close decision: driver.

---

## Slice execution order summary

| Slice | Items covered | ADRs | Notes |
|-------|--------------|------|-------|
| 1 | Multi-repo live-fire (item 1) | — | Requires Jake operator steps; cannot fully close without them |
| 2 | UI polish — timeline, home page, strip (items 2 + G6 Slice 4) | — | Can parallel with Slice 3 once Slice 1 done |
| 3 | Demo runbook + onboarding refresh (items 3, 4) | — | Can parallel with Slice 2 |
| 4 | Driver dry-run + targeted fixes (item 5) | — | Judgment-gated; close decision is driver |

Slice 1 is highest-leverage and must go first. Slices 2 and 3 can run in parallel once Slice 1 is done. Slice 4 is the close gate: no fixed deliverables, only the dry-run and the driver's judgment.

**G7 closes** when the driver, having dry-run the demo against the second-repo deployment, records their go/no-go in the ROADMAP G7 Done entry with dry-run evidence.
