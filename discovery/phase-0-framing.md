# Phase 0 Framing — Wedge Candidates

> Produced by `customer-researcher` on 2026-05-19. Stops at G0 — human picks direction.

## The question

Which subset of Guild's eight components must be real (not stubbed) for a Guild worker to credibly claim a GitHub issue in this repo, implement a change, open a PR that passes automated verification, and reach the `done` state — with thread context preserved across the full cycle? The answer defines the wedge: everything outside it is either hardcoded, seeded, or deferred to post-G2. Picking the wrong boundary means either building more than needed before G2 (wasted time) or discovering a missing load-bearing piece mid-implementation (backtracking). G0 is the gate; this document surfaces the tradeoffs so the human operator can make the call with full information.

---

## Wedge A — Thinnest end-to-end

**Short name:** Minimum wire

### In scope

| Component | Depth |
|---|---|
| Event Stream | Minimal: a single Postgres table as event queue; one webhook endpoint that accepts GitHub `issues.*` and `pull_request.*` events, validates the HMAC secret, writes a raw row, and returns 200. No normalization beyond what is needed to extract `thread_id`. No Linear, Slack, Discord, or CI callbacks. |
| Thread Model | Minimal: a single `threads` table with columns for `anchor_url`, `state`, `owner`, and a `jsonb` column for `context_notes`. No graph structure. No parent-child hierarchy. No artifact linking beyond the PR URL stored as a context note. |
| Context Assembly | Hardcoded: reads the thread row and the single triggering event row from the DB; concatenates them into a flat string. No filtering, no summarization, no freshness tracking. |
| Decision Layer | Hardcoded to one path: receives the context string, calls an LLM with a fixed system prompt, and expects a JSON response with `action`, `reasoning`, and `params`. Only the `implement` and `comment` action types are handled; all others are treated as `ignore`. |
| Action Primitives | Real, thin: `create_branch`, `commit_and_push`, `open_pull_request`, `comment_on_issue`, `update_thread_state`, `write_thread_note`, `log_decision`. The `implement` action dispatches to the Fountain adapter (per ADR 0004) via `dispatch_conversation`. `open_pull_request` is gated on a `completed` signal from the Fountain conversation. |
| State Machine | Partial: persisted as the `state` column on the thread row. Transitions implemented: `unnoticed → noticed → claimed → executing → pr_open → done`. No `planned`, no `blocked`, no `abandoned`. Illegal transitions raise an error but are not yet recoverable. |
| Social Presence | Hardcoded: one GitHub App installation used for all actions. Worker name and avatar are static config. No @mention handling. No Slack identity. |
| Work Claiming | Hardcoded: the claiming loop is a single mix task (`Guild.Tasks.ClaimSeed`) that reads a `SEED_ISSUE_URL` environment variable, writes a thread row, transitions to `claimed`, and calls `comment_on_issue` with the standard "Taking this" template. No survey, no evaluate, no conflict avoidance. Run manually. |

### Stubbed / hardcoded

- **Claiming loop**: replaced by `Guild.Tasks.ClaimSeed`, which takes a hardcoded issue URL from an env var and writes directly to the `threads` table. Run once manually via `mix guild.claim_seed`.
- **Context Assembly**: a two-row `SELECT` (thread + latest event) concatenated into a plain text string. No editorial logic. No cost optimization.
- **Event Stream normalization**: raw GitHub webhook payload is stored in a `jsonb` column. `thread_id` is extracted from the issue `node_id`. All other normalization fields (`actor`, `subject`, etc.) are left as `null` or omitted.
- **Social Presence**: GitHub App credentials are static env vars. No per-worker app installation management. No Slack bot. No @mention routing.
- **State Machine recovery**: no recovery on restart. If Guild restarts mid-execution, the thread stays in `executing` and requires manual intervention.
- **Action Primitives — planning, communication, work management**: `plan`, `ask_question`, `create_issue`, `create_sub_issue`, `assign_to_self`, `add_label`, `update_issue`, `close_issue`, `reply_in_thread`, `post_to_channel` are all unimplemented; any decision that returns these action types is logged and dropped.
- **`blocked` and `abandoned` transitions**: unimplemented. If the worker needs to ask a question, the decision returns `ignore` and the thread sits in `executing`.

### First closable issue

There are no open issues in `jhgaylor/guild` as of 2026-05-19. The first real issue closable under Wedge A would be shaped like: "Add a missing field to the `threads` table migration" or "Fix a typo in a doc file" — a self-contained change with a clear diff and no ambiguous requirements. Acceptance criteria must be explicit enough that the Fountain conversation can produce a verifiable diff. The issue should have no dependency on other issues or sub-issues. Automated verification (at minimum a CI check that compiles the Elixir project and runs `mix test`) must already exist in the repo before the worker is pointed at it — if it does not, the worker cannot satisfy the verification requirement in ADR 0005 (Action Primitives).

### Risks

The dominant risk is that Context Assembly is too thin for Fountain to produce a useful implementation. A two-row context string gives the agent almost no signal about code style, existing patterns, or project conventions. The Fountain conversation is likely to write code that compiles but doesn't fit the codebase, triggering a review cycle the state machine (which lacks `blocked`) cannot handle. The worker will be stuck in `pr_open` with no path forward. This is the piece most likely to require backtracking.

### Verdict

Choose Wedge A if the team's primary goal at G2 is to prove the end-to-end wire exists — that events arrive, a thread is created, Fountain is dispatched, a PR is opened, and the `done` state is reached — and the team is willing to treat the first worker's output quality as acceptable even if low. Best for a team that values speed of first iteration over durability of the result.

---

## Wedge B — Thread model + state machine first, claiming later

**Short name:** Memory-first

### In scope

| Component | Depth |
|---|---|
| Event Stream | Real, minimal: Postgres-backed durable queue with deduplication by event `id`. Normalized event envelope (all fields populated). GitHub webhook handler for `issues.*`, `pull_request.*`, `issue_comment.*`, `push`, `check_run.*`. `thread_id` assignment at ingestion time for explicit references (PR body containing `Fixes #N`); heuristic fallback flagged for human confirmation rather than silently guessed. |
| Thread Model | Real: full schema — anchor, events (foreign key to event queue), artifacts table (branches, PRs, commits), `state`, `owner`, `context_notes` as structured rows (not a raw jsonb blob). Parent-child thread relationship modeled with `parent_thread_id`. Graph queries for "what review feedback has this thread received?" and "what artifacts does this thread have?" are real. |
| Context Assembly | Real, basic: queries the thread graph and produces a structured context packet (work item + ordered event history + artifacts + worker notes + current event). Filtering heuristics: recency, unresolved items, human instructions always included. No summarization of old history yet — that waits until thread length makes it necessary. |
| Decision Layer | Real contract: worker receives the structured context packet; returns `{ action, reasoning, params }`. `reasoning` is written as a `context_note` on the thread. Action types `implement`, `comment`, `ask_question`, and `ignore` are handled; `ask_question` drives the `blocked` transition. |
| Action Primitives | Real: `create_branch`, `commit_and_push`, `open_pull_request`, `push_to_branch`, `comment_on_issue`, `comment_on_pr`, `assign_to_self`, `write_thread_note`, `update_thread_state`, `log_decision`, `dispatch_conversation` (Fountain adapter). |
| State Machine | Real and full: all nine states implemented. All legal transitions implemented. `blocked` handles `ask_question` decisions; `executing` resumes when a reply event arrives. Crash recovery: on startup, threads in non-terminal states are reloaded and re-evaluated. |
| Social Presence | Minimal real: one GitHub App installation, fixed identity. Comments use the standard templates from `docs/07-social-presence.md`. No @mention routing. No Slack bot. |
| Work Claiming | Stubbed: same `Guild.Tasks.ClaimSeed` mix task as Wedge A. No claiming loop, no survey, no evaluate. The thread is manually seeded. |

### Stubbed / hardcoded

- **Claiming loop**: `Guild.Tasks.ClaimSeed` — identical to Wedge A. The full survey → evaluate → select → claim loop is deferred entirely. A human manually seeds a thread with `mix guild.claim_seed ISSUE_URL=<url>`.
- **Social Presence — Slack**: no Slack App, no `reply_in_thread`, no `post_to_channel`. Social presence is GitHub-only.
- **Social Presence — @mention routing**: @mentions in GitHub issues are ingested as events but the routing logic (which worker does this mention belong to?) is hardcoded: all mentions go to the single configured worker.
- **Context Assembly — summarization**: older thread history is included verbatim until the context window forces the issue. A `TODO` comment marks where incremental summarization goes.
- **Action Primitives — planning**: `plan`, `create_issue`, `create_sub_issue`, `add_to_project` are unimplemented. A decision returning `plan` is treated as `escalate`.
- **Multi-worker**: the platform is wired for a single worker. The `owner` field on threads exists in the schema but is hardcoded to the single configured worker's identity.

### First closable issue

The first closable issue has the same shape as Wedge A (self-contained, clear acceptance criteria, no sub-issues) but the worker can now handle a review cycle: if a reviewer requests changes, the `pr.review_submitted` event arrives, the state machine transitions `pr_open → executing`, the Decision Layer assembles a fresh context packet including the review comment, and Fountain is dispatched again with the feedback. The thread model preserves the full history — approach attempted, reviewer's objection, second attempt — so the second Fountain conversation has real context to work from. A viable first issue: "Add a `context_notes` index to the threads table" or "Write the `update_thread_state` primitive's error handling path" — something where review feedback is plausible and the thread model's memory provides value.

### Risks

The dominant risk is scope creep during the thread model build. The full graph schema (events table, artifacts table, parent-child links) is materially more work than a single `threads` table, and the team may discover edge cases in thread linkage (the hardest problem called out in `docs/02-thread-model.md`) that demand more time than budgeted. The second risk is that deferring the claiming loop all the way to post-G2 means the self-hosting success metric (a worker claiming an issue unprompted) is not demonstrated until much later than Wedge A or C.

### Verdict

Choose Wedge B if the team's primary concern is operational confidence — specifically, that a worker can survive a restart, handle review feedback without losing context, and produce an audit trail that makes worker behavior debuggable. Best for a team that sees the thread model and state machine as the irreducible intellectual core of Guild, and wants that core proven before worrying about claiming autonomy.

---

## Wedge C — Event ingestion + action runner only, hardcode the rest

**Short name:** Pipe-and-primitives

### In scope

| Component | Depth |
|---|---|
| Event Stream | Real and full: Postgres-backed durable queue, deduplication by event `id`, full normalized event envelope, all webhook handlers (GitHub issues, PRs, comments, push, check_run). `thread_id` assignment via explicit reference parsing only (no heuristics). LISTEN/NOTIFY channel for downstream consumers. |
| Thread Model | Stubbed: a single `threads` table with `id`, `anchor_url`, `state` (varchar), and `raw_context` (jsonb). No artifacts table, no events foreign key, no parent-child. All context is stored as a growing jsonb blob appended to on each action. |
| Context Assembly | Hardcoded: reads `raw_context` jsonb blob, passes it verbatim to the Decision Layer. No filtering, no graph queries, no freshness tracking. |
| Decision Layer | Hardcoded: a static Elixir module with a `decide/1` function that pattern-matches on `current_event.type`. On `issues.assigned` → return `implement`. On `pull_request.review_submitted` with `state: "changes_requested"` → return `implement`. On `pull_request.merged` → return `done`. Everything else → `ignore`. No LLM call in the critical path; the "LLM" call is stubbed as a function that returns a hardcoded `implement` response. |
| Action Primitives | Real and complete: the full set from `docs/05-action-primitives.md` — all code actions, all communication actions, work management, and meta actions. Each is a typed, tested Elixir function. The Fountain adapter (`dispatch_conversation`, `observe_conversation`, `follow_up_prompt`, `interrupt_conversation`, `terminate_conversation`) is real. This is the primary build target for this wedge. |
| State Machine | Hardcoded as a column update inside each action primitive. No formal state machine module. `state` is set to `"executing"` when `dispatch_conversation` is called, `"pr_open"` when `open_pull_request` is called, `"done"` when `close_issue` is called. No illegal transition checking. |
| Social Presence | Minimal real: one GitHub App installation, standard communication templates. No @mention routing. No Slack. |
| Work Claiming | Hardcoded: `Guild.Tasks.ClaimSeed` as in Wedge A. |

### Stubbed / hardcoded

- **Thread Model graph**: replaced by a single jsonb blob (`raw_context`) that is appended to on each action. No relational structure. Thread linkage between events and the thread row is done by matching `issue_number` in the event payload against `anchor_url` — a string parse, not a foreign key join.
- **Context Assembly**: passes the raw `raw_context` jsonb blob to the decision function. No editorial filtering. As the blob grows, it will eventually overflow the context window of any LLM; there is no mitigation.
- **Decision Layer**: static Elixir `case` statement on event type. No LLM call. The first issue a worker "decides" to implement is decided entirely by whether the triggering event type matches `issues.assigned`. If requirements are unclear, the worker cannot ask; it implements anyway.
- **State Machine transitions**: raw column updates inside primitives. No transition validation. A primitive can set `state = "done"` from `state = "unnoticed"` and nothing will object. Recovery on restart is not implemented.
- **`ask_question` / `blocked` flow**: unimplemented. The static decision function never returns `ask_question`.
- **`plan` / sub-issues**: unimplemented.
- **Multi-worker**: single hardcoded worker identity throughout.

### First closable issue

The first closable issue under Wedge C must be a pure code change where no clarification is needed — the Decision Layer cannot ask questions. The ideal issue is: "Add the `dispatch_conversation` Fountain adapter implementation" — which is itself an action primitive, so the wedge is bootstrapping its own infrastructure. The worker would be seeded manually, Fountain would be dispatched (or a stub would stand in), and the PR would be opened after CI passes. The action primitive suite being real and tested is the condition that makes even this simple issue closable; until the primitives exist, the worker cannot take any action in the world.

### Risks

The dominant risk is that the jsonb blob for context grows unbounded and becomes useless for anything requiring more than one or two event cycles. A review-and-revise cycle (PR opened → changes requested → second commit → approved) appends four events to the blob; by the third or fourth cycle the blob is noise. The second risk is that the hardcoded Decision Layer cannot handle any issue that requires judgment — ambiguous requirements, a failing CI check that needs investigation, a reviewer question — so the range of issues the worker can actually close is very narrow. Both risks mean the wedge is likely to hit a wall before G3 (self-hosting cutover) and require rebuilding the Thread Model and Decision Layer from scratch rather than incrementally improving them.

### Verdict

Choose Wedge C if the team's primary goal is to produce a complete, tested Action Primitives library and a working Fountain integration before anything else — treating the primitives as the platform's foundational API and deferring everything that requires memory or judgment. Best for a team that wants to nail the action execution layer first and is comfortable rebuilding the decision and memory layers on top of a solid primitive foundation later.

---

## Recommendation

Wedge B is the strongest starting point for a team whose success metric is a Guild worker claiming and closing a real issue in its own repo with the thread model preserving context across the full cycle. The success metric explicitly names thread context preservation ("the thread model preserving context across the full claim → PR → review → merge cycle" — OPERATING_MODEL.md) — which means a wedge that stubs the thread model (A's flat table, C's jsonb blob) will require rebuilding the highest-value component before G3. Wedge B defers the claiming loop (low-risk deferral: seeding a thread manually is equivalent for G2 purposes) while building the memory and recovery infrastructure that separates Guild from a trigger system. The state machine's crash recovery in particular is load-bearing for self-hosting: if Guild restarts mid-execution while running its own worker, Wedge A and C leave threads stranded.

That said: if the team has high uncertainty about the Fountain adapter integration (the most novel external dependency), Wedge C's focus on proving that integration first — at the cost of a weaker thread model — may reduce technical risk faster. That is the human operator's call at G0.
