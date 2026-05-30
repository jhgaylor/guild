# G8 — Framing

Framing for G8 produced at the close of G7. Captain-picard decomposes this into
a slice plan; the driver reviews and approves before any slice is dispatched.

## Thesis

**Make the UI the way you operate Guild.**

Today, operating Guild after the initial kubectl deploy means dropping back to
kubectl (`add_repo`, `add worker`), GitHub.com (App install settings), Slack
(slash commands), Linear (webhook config), and a README. The Guild UI is great
for *watching* — `/threads`, `/jobs`, the interleaved timeline — but it's silent
on *discover*, *configure*, and *use*. G8 closes that gap.

The user we're optimizing for: an operator who has just deployed Guild and now
wants to run it. They should not need to read four other UIs or shell into a
pod to set up a second repo, see whether Slack is wired, or hold a thread.

## Item inventory

### 1. Landing page that actually pitches Guild *(discover)*
Issue: `/` currently shows one sentence and two nav links. A first visitor —
prospect, operator, or someone clicking from a demo — gets no sense of what
Guild does, what it's connected to, or where to start. Fix: punchier hero copy
("Guild watches your repos for `bot-ready` issues, claims them, and ships PRs —
steered from Slack, observed in here"), a short feature list with anchor links
to the relevant operator surfaces (`/threads`, `/jobs`, `/admin`), and a "Try
it on your repo" CTA linking to `docs/setup.md`. Public route. **Priority:
medium-high** — first impression for everyone.

### 2. `/admin` shell behind operator auth *(configure)*
Issue: there's no central place to configure anything. Fix: a single `/admin`
LiveView that hosts sub-tabs for repos, workers, and integration status. Behind
the existing `:auth` pipeline. **Priority: high** — every other configure item
lives under here.

### 3. Repos CRUD from the UI *(configure)*
Issue: adding a repo today is `kubectl exec ... bin/guild eval
Guild.Release.add_repo(...)`. That's a usable runbook but it shouldn't be the
only path. Fix: `/admin/repos` lists current `repos` rows (full_name, enabled,
worker_id, last-claim timestamp), with a form to add a new one (full_name +
worker_id picker + enabled toggle), inline enable/disable, and a confirmation
modal for delete. Calls the existing `Guild.Release.add_repo/3` (which is
already idempotent and Repo-safe). **Priority: high** — this is the
single biggest config gap.

### 4. Workers list + add *(configure)*
Issue: same kubectl-only situation for the `workers` table. Fix:
`/admin/workers` lists configured workers (worker_id, fountain_agent_id,
vault_id, github_installation_id) read-only; a form adds a new one. Secrets
themselves stay in the live k8s Secret — the UI only references their presence,
not values. **Priority: medium** — most deployments will use the default worker
for a while.

### 5. Integration status dashboard *(discover + use)*
Issue: nothing tells the operator at a glance whether their integrations are
healthy. Fix: `/admin/integrations` shows one card per integration —
GitHub App (installed on N repos, last webhook delivery), Slack (signing
secret present + last outbound success), Linear (API key + state IDs present +
last outbound success), Fountain (API key + last `get_status` success). Each
card resolves to "✓ ready", "⚠ unconfigured", or "✗ failing" based on
config presence and recent activity. **Priority: high** — the "is this thing
actually wired up?" question every operator asks.

### 6. Setup-readiness banner *(discover + configure)*
Issue: if the operator deploys but forgets to seed a repo, Guild silently
ignores webhooks for everything. Same risk for unconfigured workers. Fix: a
small banner on `/` and `/threads` that detects missing-but-required config
(zero `repos` rows, zero `workers` rows) and links to the relevant admin page.
**Priority: medium** — failure-mode safety net.

### 7. Inline thread actions on `/threads/:id` *(use)*
Issue: hold/abandon today require Slack or `kubectl eval`. Fix: Hold / Resume /
Abandon buttons on the thread detail view (behind operator auth) that POST to a
small `Guild.Control`-backed endpoint. Same control logic, in-UI button.
**Priority: medium** — closes the last "but I have to go to Slack to do this"
gap.

### 8. "Try it" first-issue helper *(stretch — may defer to G9)*
Issue: a fresh deploy with one configured repo still needs someone to know to
go to GitHub and add a `bot-ready` label. Fix: on `/admin/repos`, a small "Open
a test issue" button that creates an issue via the GitHub App and applies the
label. Useful for the very-first-run "see Guild do its thing" moment.
**Priority: low** — UI sugar, not load-bearing.

## Suggested execution order

1. **G8 slice 1 — landing page + `/admin` shell + integration status (items
   1, 2, 5).** Discover and the dashboard go in first; they're the visible
   surfaces and they have no dependencies on schema or write paths.
2. **G8 slice 2 — repos CRUD + setup-readiness banner (items 3, 6).** The
   single highest-value configure surface, plus the banner that detects
   missing config.
3. **G8 slice 3 — workers list/add + inline thread actions (items 4, 7).**
   Rounds out configure and adds the in-UI use surface.
4. **G8 slice 4 — driver dry-run with a non-driver-style pass + targeted
   fixes + stretch (item 8 if scope allows).** Judgment-gated close, same
   pattern as G7.

Slices 1 and 2 are the heart of G8; if 3 gets compressed, that's OK.

## Closing criterion

**G8 closes** when the driver, having walked through the UI as if onboarding
themselves to a fresh deploy (configure a repo, see integration status, hold a
thread — all without leaving the UI), judges Guild's UI ready for a non-driver
operator to run with. Recorded in the ROADMAP G8 entry with dry-run evidence.

## Open architectural questions for the slice plan

- **LiveView or controllers for `/admin`?** Most of `/admin` is forms +
  list/edit — LiveView gives instant feedback but adds complexity. A
  controller+template approach is simpler and matches `/threads`. Recommend
  starting with controllers; promote individual pages to LiveView only where
  real-time updates matter (integration status feels real-time; CRUD does not).
- **Where do "last activity" timestamps come from?** Recent webhook delivery,
  recent outbound, etc. Either query existing `events` rows (slow at scale,
  fine for v1) or add small `last_*_at` fields per integration. Recommend
  query for v1, denormalize later if needed.
- **Repo delete semantics:** soft (set `enabled: false`) or hard? Recommend
  toggle-disabled for v1; a hard delete is rarely what the operator wants.
- **Secret presence display:** showing "signing secret is set" requires
  reading the live `Application.get_env(:guild, :slack_signing_secret)` — fine,
  it's already what the controller does. Never display the value itself.
