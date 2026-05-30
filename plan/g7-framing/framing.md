# G7 — Framing

Framing for G7 produced at the close of G6. Captain-picard decomposes this into
a slice plan; the driver reviews and approves before any slice is dispatched.

## Thesis

**Get Guild to first-customer-demo readiness.**

The closing criterion is the driver's judgment: when I would be comfortable
sitting next to a prospect, opening a real repo (not `jhgaylor/guild`),
creating a `bot-ready` issue, and watching Guild claim it + ship a PR — without
wincing at rough edges and without the prospect saying "but does it work on MY
repo?". Concretely:

- A 5-minute live demo runs end-to-end on a **second real repo** (the G4
  multi-repo plumbing is still completely untested end-to-end).
- The operator UI tells the story clearly enough that a stranger gets it.
- The prospect has a credible path to try it themselves — a README or
  runbook that walks "fork → deploy → bot-ready issue → PR" without me
  in the loop.
- No obvious rough edges would embarrass us in the demo (the things a dry-run
  surfaces).

What G7 is **not**: SaaS billing, multi-tenant auth, hosted/managed Guild, a
public marketing site, self-serve onboarding. Those are post-G7 if and when
demos turn into real interest.

## Item inventory

### 1. Multi-repo prove-out on a real second repo *(highest leverage)*
Issue: G4 plumbed `workers`/`repos` tables, webhook routing, per-worker
credentials, the seed step — and the live system has only ever run on
`jhgaylor/guild` with the `default` worker. The "Guild on your repo" claim is
entirely hypothetical. A demo cannot land that doesn't work on a second repo.
Fix: pick a real second repo (one of Jake's existing repos with real, low-risk
work — README polish, CHANGELOG, docs touch-ups — that the worker can ship), add
its `repos` row, install/configure the Guild GitHub App on it, create a
`bot-ready` issue on it, watch the full claim→PR→merge cycle. Document every
manual step the operator took. **Priority: highest** — without this nothing
else matters for the demo.

### 2. Operator UI polish for the demo screen
Issue: the operator UI is functional but utilitarian. The home page is mostly
blank; `/threads` is a bare list; the thread detail view is sectioned tables
(not the interleaved timeline G5 Slice 1 deferred). A prospect watching needs
to follow what Guild is doing in real time. Fix: (a) homepage that says what
Guild is in two sentences + links to `/threads` and `/jobs`; (b) interleaved
chronological thread timeline (the G6 Slice 4 stretch deferred from G6) with a
"snapshot trimmed" indicator on retention-nulled decisions; (c) a small
"What just happened" strip on `/threads` showing the last few state
transitions across all threads. **Priority: high** — this is the demo screen.

### 3. Demo runbook + script
Issue: a demo without a script gets fumbled. There's no documented end-to-end
demo flow. Fix: `docs/demo.md` covering (a) the 5-minute version (here's an
issue, here's the claim, here's the PR, here's how to steer it from Slack);
(b) the 15-minute deep dive (Oban queue, owner CAS, reconcile, observability,
Slack control plane); (c) the "try it on your repo" preamble. **Priority:
high** — demo-readiness without a runbook is fragile.

### 4. Onboarding refresh — "deploy Guild on your repo"
Issue: the README explains what Guild is but not how a prospect deploys it on
their own repo. PREREQUISITES.md exists but is dated. The fork-and-run path is
real (G4 verified the secrets/migrations/seed work) but undocumented as a
flow. Fix: README has a clear "Try it on your repo" section linking to a
focused setup runbook (`docs/setup.md`) covering: fork → build CI → GitHub
App → secrets → deploy → first `bot-ready` issue. Pull from the work already
done in CONTRIBUTING.md and PREREQUISITES.md. **Priority: medium-high** —
needed for the "credible path" part of the criterion.

### 5. Robustness sweep from a demo dry-run *(judgment-gated)*
Issue: nothing surfaces rough edges like a dry-run demo. Things like
loading-state flicker, ugly error pages, weirdly-formatted Slack messages,
the home page showing nothing useful — these only show up when watched. Fix:
do a dry-run, list every wince-worthy thing, fix what's cheap. The driver
runs this slice and decides when good enough. **Priority: judgment-call** —
size and scope set by what the dry-run finds.

### 6. Linear `:executing` actually exercised *(stretch)*
Issue: G6 wired the Linear `:executing → In Progress` transition but no Linear
team is configured, so it's untested live. Nice-to-have for the demo if a
prospect uses Linear. Fix: if Jake has a Linear workspace willing to host a
test team, configure it and watch the transition fire during the dry-run.
**Priority: low** — only matters if the demo audience cares about Linear.

## Suggested execution order

The thesis ("driver judges demo-ready") means slice ordering is in service of
the dry-run, not a fixed plan. Suggested:

1. **G7 slice 1 — multi-repo live-fire on a second real repo.** Highest
   leverage and biggest existing risk. Closes the "Guild on your repo" gap.
2. **G7 slice 2 — UI polish for the demo screen.** Interleaved timeline, home
   page, "What just happened" strip.
3. **G7 slice 3 — demo runbook + onboarding refresh.** `docs/demo.md` +
   `docs/setup.md` + README "Try it on your repo" section.
4. **G7 slice 4 — driver dry-run + targeted fixes.** This is where the close
   decision lives. Run a real demo against the second repo, list and fix
   what's rough, then close G7 when the bar is met.

Slices 2 and 3 can run in either order (or parallel) once 1 is done.

## Closing criterion

**G7 closes** when the driver, having dry-run the demo against the second-repo
deployment, judges it ready to show to a real prospect — and records that
decision in the ROADMAP G6/G7 entry with the dry-run evidence.

## Open architectural questions for the slice plan

- **Which second repo for the multi-repo prove-out (slice 1)?** A real repo of
  Jake's with low-risk work (README/CHANGELOG/docs polish issues) is ideal.
  The driver will pick during slice 1 dispatch (likely an existing public repo
  Jake owns; if none fits, create a small playground repo).
- **Same Guild instance or separate?** The G4 multi-repo design is one
  deployment serving N repos. Slice 1 verifies the single-deployment path
  (add the second repo's row, install the App, run). No second deployment.
- **GitHub App scope (slice 1):** the existing `guild-app-secrets` GitHub App
  installation covers `jhgaylor/guild` only. Slice 1 needs the App installed
  on the second repo too — installation is an out-of-band Jake action,
  documented in the runbook.
- **Demo audience (informs slices 2–4):** technical founder vs. less-technical
  PM vs. eng leader changes what the UI/docs emphasize. Default to "technical
  founder evaluating Guild for their team" until told otherwise.
