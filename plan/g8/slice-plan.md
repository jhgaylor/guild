# G8 Slice Plan

**Generated:** 2026-05-30
**Source:** plan/g8-framing/framing.md
**Gate:** Driver reviews and approves this plan before any slice is dispatched.

G8 closes when the driver, having walked through the UI as if onboarding to a fresh deploy (configure a repo, see integration status, hold a thread — all without leaving the UI), judges Guild's UI ready for a non-driver operator to run with. The slice plan is in service of that judgment, not a fixed item list. Ordering is highest-value-first.

**Architectural questions settled here (framing open questions resolved):**
- **Controllers over LiveView for `/admin` CRUD:** Most of `/admin` is forms + list/edit. Controllers + templates match the existing `/threads` pattern and are simpler. Individual pages may be promoted to LiveView later if real-time feedback is needed. Integration status (item 5) is the one candidate — render it server-side for v1, revisit if operators want auto-refresh.
- **Last-activity timestamps via query:** Query existing `events` rows for last webhook delivery and existing `artifacts` rows for last outbound Slack/Linear success. Fine at current volume. Denormalize with `last_*_at` columns if query cost becomes a concern (G9+).
- **Repo delete = soft-disable:** Set `enabled: false`, never hard-delete. Operators almost never want irreversible deletes; threads referencing the repo keep their foreign key intact. A "Re-enable" toggle undoes a soft-delete.
- **Secret presence = `Application.get_env` check:** Integration status cards read the live application config (already set from env at startup). Never display the value itself — "GitHub App ID: set" is sufficient signal.

**No ADRs required** — all decisions above are settled inline by the framing.

---

## Slice 1 — Landing Page + `/admin` Shell + Integration Status (Items 1, 2, 5)

**Goal:** Give every visitor a clear first impression of Guild and give operators a central place to see whether their integrations are healthy — before touching any write paths.

### In-scope

- **Enhanced home page** (`lib/guild_web/controllers/page_html/home.html.heex`): Replace the current minimal pitch with punchy hero copy ("Guild watches your repos for `bot-ready` issues, claims them, and ships PRs — steered from Slack, observed in here"), a short feature list with anchor-links to `/threads`, `/jobs`, and `/admin`, and a "Try it on your repo" CTA pointing to `docs/setup.md`. Public route (no auth).
- **`/admin` shell** (`lib/guild_web/controllers/admin_controller.ex` + `lib/guild_web/controllers/admin_html/` + router wiring): `GET /admin` renders an index page with sub-navigation to Repos, Workers, and Integrations. Behind the existing `:auth` pipeline. `lib/guild_web/router.ex`: add a `scope "/admin"` block under the `:auth` pipeline.
- **Integration status dashboard** (`GET /admin/integrations`): One card per integration, each resolving to "✓ ready" / "⚠ unconfigured" / "✗ failing":
  - **GitHub App:** `GITHUB_APP_ID` + `GITHUB_INSTALLATION_ID` + `GITHUB_PRIVATE_KEY` present; last webhook delivery = most recent `events` row with `source: "github"` (nil if none).
  - **Slack:** `SLACK_SIGNING_SECRET` present; `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID` present for outbound; last outbound success = most recent `artifacts` row with `artifact_type: "slack_message"` (url not nil).
  - **Linear:** `LINEAR_API_KEY` + `LINEAR_STATE_IN_PROGRESS_ID` + `LINEAR_STATE_DONE_ID` present; last outbound = most recent `artifacts` row with `artifact_type: "linear_issue"`.
  - **Fountain:** `FOUNTAIN_API_KEY` + `FOUNTAIN_BASE_URL` + `GUILD_IMPLEMENTER_AGENT_ID` present; no live probe (avoid runtime API calls on page load).
- Tests: home page 200 + hero copy + CTA link; `/admin` 200 behind auth (401 without); `/admin/integrations` 200 + all four cards rendered; card resolves to "⚠ unconfigured" when env vars absent (use `Application.put_env` in test setup).

### Stubbed at this slice

- Real-time auto-refresh of integration status (poll or LiveView push).
- Live probe calls (e.g. Fountain `get_status`) on page load — presence check only.
- Admin sub-navigation tabs as separate LiveView processes.

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Home page renders hero copy, feature list, and "Try it on your repo" CTA.
- `GET /admin` renders with sub-navigation; returns 401 without auth.
- `GET /admin/integrations` renders four integration cards with correct status signals.

### Depends on

G7 main (already merged). No other slices.

### Estimate

~250 LOC (controller + templates + tests). One engineer.

---

## Slice 2 — Repos CRUD + Setup-Readiness Banner (Items 3, 6)

**Goal:** Let operators add, enable/disable, and (soft-)delete repos without touching `kubectl`. Add a safety-net banner so operators discover missing-but-required config before they wonder why nothing is happening.

### In-scope

- **`/admin/repos`** — list + add + toggle + soft-delete:
  - `GET /admin/repos`: lists all `Guild.Schema.Repo` rows (full_name, enabled, worker_id, last-claim timestamp = most recent `threads` row for that repo ordered by `inserted_at`).
  - `POST /admin/repos`: add form (full_name + worker_id picker from workers table + enabled toggle). Calls `Guild.Release.add_repo/3` (already idempotent via `on_conflict: :nothing`). Returns validation error if full_name blank.
  - `PATCH /admin/repos/:id/toggle`: flips `enabled` boolean. No confirmation modal.
  - `DELETE /admin/repos/:id`: sets `enabled: false` (soft-disable). Labelled "Disable" in the UI, not "Delete". No hard deletes.
  - Confirmation step: clicking "Disable" shows an inline "Are you sure?" confirm form (no JS modal needed — a second POST suffices).
- **Setup-readiness banner** — rendered as a shared partial (`lib/guild_web/components/readiness_banner.html.heex` or inline in relevant layouts):
  - Conditions checked: zero enabled `repos` rows, zero `workers` rows. Each missing condition renders a specific link to the relevant admin page.
  - Rendered on: `GET /` (home page) and `GET /threads` (index). Behind their respective auth/public context — home page banner visible to all, /threads banner behind auth.
  - Dismissed automatically when the condition is resolved (stateless check on every render).
- Tests: `GET /admin/repos` lists repos; `POST /admin/repos` with valid params creates row; `POST /admin/repos` with blank full_name returns error; `PATCH /admin/repos/:id/toggle` flips enabled; `DELETE /admin/repos/:id` soft-disables. Banner test: zero repos → banner present; one enabled repo → banner absent.

### Stubbed at this slice

- Hard delete (irreversible). Use soft-disable.
- Per-repo GitHub App installation automation.
- Pagination on the repos list.
- "Try it" first-issue helper (item 8 — stretch in Slice 4).

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Operator can add a second repo row from the UI without `kubectl`.
- Enable/disable toggle and soft-delete work.
- Setup-readiness banner appears on `/` and `/threads` when zero repos or zero workers are configured; disappears when fixed.

### Depends on

Slice 1 merged (needs `/admin` shell + router scope).

### Estimate

~300 LOC (controller + templates + tests). One engineer.

---

## Slice 3 — Workers List/Add + Inline Thread Actions (Items 4, 7)

**Goal:** Round out the configure surface with a workers UI, and close the last "I have to leave the UI to hold a thread" gap with inline Hold/Resume/Abandon buttons on the thread detail.

### In-scope

- **`/admin/workers`** — list + add:
  - `GET /admin/workers`: lists all `Guild.Schema.Worker` rows (worker_id, fountain_agent_id, vault_id, github_installation_id). Read-only display; no edit form (secrets stay in k8s Secret).
  - `POST /admin/workers`: add form (worker_id, fountain_agent_id, vault_id, github_installation_id). Inserts a new `workers` row. Validation: worker_id required and unique.
  - Secrets (`FOUNTAIN_API_KEY` etc.) are never shown or accepted through this form — only the non-secret reference IDs.
- **Inline thread actions** on `/threads/:id`:
  - Hold, Resume, and Abandon buttons rendered when the action is valid for the thread's current state (Hold shown when `held=false` and state is `:executing` or `:pr_open`; Resume when `held=true`; Abandon when not already terminal).
  - `POST /threads/:id/hold`, `POST /threads/:id/resume`, `POST /threads/:id/abandon` — three small controller actions, each calling the corresponding `Guild.Control` function and redirecting back to `GET /threads/:id`.
  - Behind operator auth (existing `:auth` pipeline via `live_session` `on_mount` for the LiveView; the new POST endpoints go through the same `:auth` pipeline scope).
  - No JavaScript required — standard form POSTs with redirect.
- Tests: `GET /admin/workers` lists workers; `POST /admin/workers` creates row; `POST /threads/:id/hold` calls `Guild.Control.hold/1` and redirects; `POST /threads/:id/resume` and `abandon` similarly; buttons absent for terminal threads.

### Stubbed at this slice

- Worker edit / update (worker_id is the PK; changing other fields is an operator-managed Secret update).
- Worker delete.
- Real-time LiveView push of state changes after hold/resume/abandon (redirect is sufficient for v1).

### ADRs required

None.

### Acceptance criteria

- `mix test --exclude e2e` green.
- Operator can add a workers row from the UI.
- Hold/Resume/Abandon buttons appear on `/threads/:id` and call the correct `Guild.Control` action.
- Buttons absent or disabled for terminal-state threads (`:done`, `:abandoned`).

### Depends on

Slice 2 merged (needs `/admin` router scope, consistent with the rest of the admin shell).

### Estimate

~250 LOC (controller + templates + tests + thread action endpoints). One engineer.

---

## Slice 4 — Driver Dry-Run + Targeted Fixes (Judgment-Gated Close)

**Goal:** Walk through the UI as a non-driver operator onboarding to a fresh Guild deploy, surface what is rough, fix what is cheap, and close G8 when the bar is met. Stretch: "Try it" first-issue helper (item 8) if scope allows.

### Dry-run checklist (driver executes — non-driver-style)

The driver approaches the live deployment as if they had never operated Guild before:

**Discover:**
- Load `/` — does the hero copy explain what Guild does in one reading? Is the CTA clear?
- Is the setup-readiness banner visible (or correctly absent) given the current live config?
- Navigate to `/admin/integrations` — do all four cards show the correct status? Any card showing ✗ when the integration is actually working?

**Configure:**
- Navigate to `/admin/repos` — are all repos listed with correct enabled status and last-claim timestamp?
- Add a new repo (or re-add an existing one) — confirm idempotent round-trip.
- Toggle enable/disable — confirm live effect.
- Navigate to `/admin/workers` — is the default worker visible with correct fountain_agent_id and vault_id?

**Use:**
- Open a thread that is in `:executing` or `:pr_open`.
- Click Hold — confirm thread enters held state and the UI reflects it.
- Click Resume — confirm thread returns to active.
- Open a terminal thread — confirm Hold/Resume/Abandon absent.

**End-to-end sanity:**
- Create a `bot-ready` issue → watch `/threads` for the new thread and setup-readiness banner behaviour.
- Confirm `/jobs` shows the ClaimWorker job processed.
- Watch thread reach `:done`; confirm Slack message if wired.

### What to capture during the dry-run

- Wince-worthy moments (confusing copy, missing feedback, awkward flow).
- Blocking defects (errors, broken actions, missing routes).
- Quick-fix (≤ 1–2 hours) vs. G9-defer candidates.

### Fix scope

Blocking defects and wince-worthy moments that are ≤ 1–2 hours each. Defer larger items to G9. Document what was fixed and what was deferred in the ROADMAP G8 Done entry.

### Stretch: "Try it" first-issue helper (item 8)

If the dry-run surfaces no blocking defects and scope allows, add a "Open a test issue" button on `/admin/repos` that creates a GitHub issue with the `bot-ready` label via the GitHub App installation. Useful for the very-first-run moment. If the dry-run produces fixes that consume the available time, defer to G9.

### Stubbed at this slice

- Systematic UX review beyond what the dry-run surfaces.
- Performance or load testing.
- Multi-tenant / SaaS concerns.

### ADRs required

None.

### Acceptance criteria

Driver judgment: "I can sit in front of a fresh Guild deploy, navigate to `/admin`, configure a repo, see that my integrations are healthy, and hold a thread — without leaving the browser." Evidenced by dry-run checklist completed and the deferred list recorded in ROADMAP.

### Depends on

Slices 1, 2, and 3 merged.

### Estimate

Dry-run: 1–2 hours. Fixes: judgment-scoped (0–1 day). Stretch item 8: ~100 LOC if pursued. Close decision: driver.

---

## Slice execution order summary

| Slice | Items covered | ADRs | Notes |
|-------|--------------|------|-------|
| 1 | Landing page (1) + `/admin` shell (2) + integration status (5) | — | No write paths; discover surfaces first |
| 2 | Repos CRUD (3) + setup-readiness banner (6) | — | Highest-value configure surface; depends on Slice 1 |
| 3 | Workers list/add (4) + inline thread actions (7) | — | Rounds out configure + closes Slack dependency for hold/resume |
| 4 | Driver dry-run + targeted fixes + stretch item 8 | — | Judgment-gated; no fixed deliverables |

Slice 1 goes first (discover surfaces, no write paths, sets up the `/admin` router scope). Slice 2 follows immediately (highest-value configure item). Slice 3 after Slice 2. Slice 4 closes G8: no fixed deliverables, only the dry-run and the driver's judgment.

**G8 closes** when the driver records their go/no-go in the ROADMAP G8 Done entry with dry-run evidence.
