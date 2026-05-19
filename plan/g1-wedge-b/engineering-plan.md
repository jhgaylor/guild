# G1 Engineering Plan — Wedge B (Thread Model + State Machine First)

## Overview

Wedge B builds Guild's durable memory and recovery core: a fully normalized event stream, a
relational thread model (with artifacts and structured context notes), a complete nine-state
machine persisted in Postgres, and a real worker decision contract backed by the Fountain adapter.
The claiming loop is stubbed as a one-shot Mix task (`Guild.Tasks.ClaimSeed`) that seeds a single
thread for the G2 end-to-end run. Social presence is GitHub-only with a single static App
installation. "Done" at G2 means a worker can survive a Guild restart mid-execution, handle a
review-and-revise cycle with full context continuity, and produce a readable audit trail.

---

## Schemas

### events

Persistent, normalized representation of every external event received. Primary feed for context
assembly and thread linkage.

```
events
  id              :: uuid, PK
  source          :: varchar  -- "github" | "linear" | "slack" | "discord" | "ci"
  type            :: varchar  -- e.g. "issues.assigned", "pull_request.review_submitted"
  timestamp       :: utctimestamp, not null
  actor           :: jsonb    -- { id, name, handle, source_id }
  subject         :: jsonb    -- { type, id, url, title }
  thread_id       :: uuid, FK → threads.id, nullable (null = not yet linked)
  raw             :: jsonb    -- original payload, unmodified
  inserted_at     :: utctimestamp, not null, default now()
```

**Indexes:**
- `(thread_id, timestamp)` — primary context-assembly query (all events for a thread, ordered)
- `(source, type, timestamp)` — event feed queries and deduplication audit
- unique on `(source, raw->>'id')` — deduplication by source-native event ID

---

### threads

The central unit of work. One row per issue/task being tracked.

```
threads
  id                :: uuid, PK
  anchor_type       :: varchar    -- "github_issue" | "linear_issue" (discriminator for anchor polymorphism)
  anchor_id         :: varchar    -- source-native issue ID (e.g. GitHub node_id or Linear UUID)
  anchor_url        :: text       -- human-readable URL for display and linking
  state             :: varchar    -- one of the nine state-machine states (see State Machine)
  owner             :: varchar    -- worker identity string or null (unassigned)
  parent_thread_id  :: uuid, FK → threads.id, nullable (null = top-level thread)
  inserted_at       :: utctimestamp, not null, default now()
  updated_at        :: utctimestamp, not null, default now()
```

**Indexes:**
- `(state)` — recovery queries on startup ("all threads in non-terminal states")
- `(anchor_type, anchor_id)` unique — prevent duplicate threads for the same work item
- `(parent_thread_id)` — child-completion queries for planned → done transitions
- `(owner, state)` — per-worker active-work queries

---

### artifacts

Things created as part of the work: branches, PRs, commits. Each is owned by exactly one thread.

```
artifacts
  id              :: uuid, PK
  thread_id       :: uuid, FK → threads.id, not null
  artifact_type   :: varchar  -- "branch" | "pull_request" | "commit" | "issue_comment"
  source          :: varchar  -- "github" | "linear" (which system owns this artifact)
  external_id     :: varchar  -- source-native ID (PR number, commit SHA, etc.)
  url             :: text     -- canonical URL
  metadata        :: jsonb    -- artifact-type-specific fields (title, state, review_state, etc.)
  inserted_at     :: utctimestamp, not null, default now()
```

**Indexes:**
- `(thread_id, artifact_type)` — context-assembly query ("open PRs for this thread")
- `(source, external_id)` unique — prevent duplicate artifact rows for the same external object
- `(artifact_type, metadata->>'state')` — status-filtered queries (e.g. open PRs only)

---

### context_notes

Structured notes written onto a thread by workers. Not visible externally — internal memory only.
Each note records a discrete piece of reasoning, decision, or status.

```
context_notes
  id              :: uuid, PK
  thread_id       :: uuid, FK → threads.id, not null
  author          :: varchar  -- worker identity string or "system" for Guild-generated notes
  note_type       :: varchar  -- "decision" | "attempt" | "blocker" | "status" | "human_instruction"
  body            :: text     -- human-readable content of the note
  inserted_at     :: utctimestamp, not null, default now()
```

**Indexes:**
- `(thread_id, inserted_at)` — context-assembly query (ordered notes for a thread)
- `(thread_id, note_type)` — filtered retrieval (e.g. only "human_instruction" notes, always included)

---

### decisions_log

Audit trail for every decision made by the decision layer, including `ignore`. Captures what the
worker saw and what it decided, for debuggability and retrospective analysis.

```
decisions_log
  id                :: uuid, PK
  thread_id         :: uuid, FK → threads.id, not null
  decision_type     :: varchar  -- action type returned: "implement" | "comment" | "ask_question" |
                                --   "plan" | "claim" | "ignore" | "escalate"
  reasoning         :: text     -- the worker's reasoning field, verbatim
  params            :: jsonb    -- the worker's params map, verbatim
  context_snapshot  :: jsonb    -- the full context packet delivered to the worker at decision time
  inserted_at       :: utctimestamp, not null, default now()
```

**Indexes:**
- `(thread_id, inserted_at)` — per-thread decision history
- `(decision_type, inserted_at)` — fleet-level decision analytics and debugging
- `(inserted_at)` — retention policy enforcement (range deletes on old rows)

---

## State Machine

Nine states. Every transition is persisted to `threads.state` inside a DB transaction. Illegal
transitions raise `Guild.StateMachine.IllegalTransitionError` — they are never silently ignored.

### Transition Table

| From | Event / Action | Guard | To | Side Effects Written | Crash Recovery |
|---|---|---|---|---|---|
| `unnoticed` | relevant event ingested + thread resolved | thread.state == `unnoticed` | `noticed` | context_note (system, "noticed") | re-ingest event on startup; idempotent |
| `noticed` | worker returns `claim` action | thread.state == `noticed`, owner is null | `claimed` | context_note (worker, "claimed"), assign_to_self call, comment_on_issue | re-evaluate from `claimed`; assign_to_self is idempotent |
| `noticed` | worker returns `ignore` | thread.state == `noticed` | `unnoticed` | decisions_log entry | safe to replay; no side effects |
| `claimed` | `dispatch_conversation` called | thread.state == `claimed`, owner == caller | `executing` | artifact (fountain_conversation), context_note "dispatching" | on startup: check Fountain conversation status via `get_status/1`; if still running, re-attach; if completed, process result |
| `executing` | `open_pull_request` returns ok | thread.state == `executing`, verification passed | `pr_open` | artifact (pull_request), context_note "pr opened", comment_on_issue | on startup: check GitHub PR state; if merged → `done`; if open → resume `pr_open` watch |
| `executing` | `create_sub_issue` × N all succeed | thread.state == `executing` | `planned` | artifact × N (issues), context_note "decomposed", child threads created | on startup: re-check child thread states; if all terminal → advance to `done` |
| `executing` | worker returns `ask_question` | thread.state == `executing` | `blocked` | context_note (worker, "blocked: <question>"), comment_on_issue | thread stays `blocked`; re-evaluate when human-reply event arrives |
| `pr_open` | `pull_request.review_submitted` event (changes_requested) | thread.state == `pr_open` | `executing` | context_note "review received: changes requested", `dispatch_conversation` with review context | on startup: check Fountain status; attach or re-dispatch |
| `pr_open` | `pull_request.merged` event | thread.state == `pr_open` | `done` | context_note "done", close_issue | `done` is terminal; no action on restart |
| `blocked` | human-reply event arrives on thread | thread.state == `blocked` | `executing` | context_note "unblocked: <reply summary>", `dispatch_conversation` | on startup: if `blocked` and reply event already in events table → resume `executing` |
| `planned` | Guild automation: all child threads reach terminal state | thread.state == `planned`, all children in `done` or `abandoned` | `done` | context_note "all children terminal", (optional) parent comment | on startup: re-query child states; advance if already terminal |
| any active | worker returns `escalate` / explicit human instruction / repeated failure | thread.state not in [`done`, `abandoned`] | `abandoned` | context_note "abandoned: <reason>", decisions_log entry | `abandoned` is terminal; no action on restart |

**Active states** (non-terminal, subject to recovery on startup): `noticed`, `claimed`, `executing`, `pr_open`, `blocked`, `planned`.
**Terminal states**: `done`, `abandoned`.

---

## Worker Decision Contract

### Input shape

The context packet delivered to the worker before every decision call. Assembled by
`Guild.ContextAssembly.build/1`.

```elixir
%Guild.Worker.ContextPacket{
  work_item: %{
    title:                String.t(),
    description:          String.t(),
    acceptance_criteria:  String.t() | nil,
    labels:               [String.t()],
    priority:             String.t() | nil,
    reporter:             String.t() | nil,
    assignee:             String.t() | nil
  },
  history: [%{
    event_type:   String.t(),
    timestamp:    DateTime.t(),
    actor:        String.t(),
    summary:      String.t()   # pre-rendered one-liner; raw not included to save tokens
  }],
  artifacts: %{
    open_prs:        [%{url: String.t(), title: String.t(), review_state: String.t()}],
    recent_commits:  [%{sha: String.t(), message: String.t(), timestamp: DateTime.t()}],
    failing_checks:  [%{name: String.t(), url: String.t()}]
  },
  conversations: [%{
    source:     String.t(),      # "github_issue" | "github_pr" | "slack"
    timestamp:  DateTime.t(),
    author:     String.t(),
    body:       String.t()
  }],
  worker_notes: [%{
    note_type:   String.t(),
    body:        String.t(),
    inserted_at: DateTime.t()
  }],
  current_event: %{
    source:     String.t(),
    type:       String.t(),
    timestamp:  DateTime.t(),
    actor:      map(),
    subject:    map(),
    raw:        map()
  }
}
```

### Output shape

The structured decision returned by the worker implementation and validated by Guild before routing.

```elixir
%Guild.Worker.Decision{
  action: :implement | :plan | :ask_question | :comment
        | :claim | :ignore | :escalate,
  reasoning: String.t(),   # required; written as a context_note on the thread
  params: %{
    # action-specific; examples:
    # :implement  → %{prompt: String.t(), agent_ref: String.t()}
    # :ask_question → %{question: String.t(), target: "issue" | "pr" | "slack"}
    # :comment    → %{body: String.t(), target: "issue" | "pr"}
    # :escalate   → %{reason: String.t()}
  }
}
```

`reasoning` is never optional. Guild rejects a decision with an empty or missing `reasoning` field
before it reaches the action router — the worker does not get a retry; the thread moves to
`blocked` with a system context note explaining the rejection.

### Error handling

Errors are typed and determine the recovery path. No error variant is silently swallowed.

| Variant | Elixir tag | Semantics | Guild response |
|---|---|---|---|
| **Transient** | `{:error, :transient, reason}` | Expected intermittent failure: network timeout, rate limit, upstream 5xx | Retry with exponential backoff (max 3 attempts, configurable); if all retries exhausted, promote to `:permanent` |
| **Permanent** | `{:error, :permanent, reason}` | Unrecoverable for this action: 404 resource not found, 403 permission denied, schema validation failure | Write context_note with reason; transition thread → `blocked`; human must intervene |
| **Unexpected** | `{:error, :unexpected, reason}` | Unrecognized error form or assertion failure — indicates a bug in the primitive or adapter | Write context_note with full error; transition thread → `abandoned`; escalate to human via comment_on_issue |

---

## Action Primitive Surface

Every primitive returns `{:ok, result}` or a typed error tuple. Primitives do not contain decision
logic. Primitives that touch external systems record their outcome to Postgres before returning.

### Code

```elixir
@spec create_branch(repo :: String.t(), branch_name :: String.t(), base :: String.t())
  :: {:ok, %{ref: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Writes artifact(thread_id, "branch", "github", branch_name, url).

@spec commit_and_push(repo :: String.t(), branch :: String.t(),
                      files :: [{path :: String.t(), content :: String.t()}],
                      message :: String.t())
  :: {:ok, %{sha: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Writes artifact(thread_id, "commit", "github", sha, url).

@spec open_pull_request(repo :: String.t(), branch :: String.t(), base :: String.t(),
                        title :: String.t(), body :: String.t())
  :: {:ok, %{pr_number: integer(), url: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Guard: verification must have passed (signaled by Fountain conversation
# reaching `completed`). Writes artifact(thread_id, "pull_request", "github", pr_number, url).
# Transitions thread → pr_open.

@spec update_pull_request(repo :: String.t(), pr_number :: integer(), body :: String.t())
  :: {:ok, :updated} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. No new artifact; updates existing PR artifact metadata.

@spec push_to_branch(repo :: String.t(), branch :: String.t(),
                     files :: [{path :: String.t(), content :: String.t()}],
                     message :: String.t())
  :: {:ok, %{sha: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Writes artifact(thread_id, "commit", "github", sha, url).
```

### Planning

```elixir
@spec create_issue(tracker :: :github | :linear, project :: String.t(),
                   title :: String.t(), body :: String.t(),
                   labels :: [String.t()], assignee :: String.t() | nil)
  :: {:ok, %{issue_id: String.t(), url: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API or Linear API. Writes artifact(thread_id, "issue", source, issue_id, url).

@spec create_sub_issue(tracker :: :github | :linear, parent_id :: String.t(),
                       title :: String.t(), body :: String.t(), labels :: [String.t()])
  :: {:ok, %{issue_id: String.t(), thread_id: Ecto.UUID.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Creates a child issue + a new Guild thread row with parent_thread_id = current thread.
# Writes artifact. Guild monitors child thread for terminal state to drive planned → done.

@spec update_issue(tracker :: :github | :linear, issue_id :: String.t(), fields :: map())
  :: {:ok, :updated} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub/Linear API. No new artifact; updates existing issue artifact metadata.

@spec close_issue(tracker :: :github | :linear, issue_id :: String.t(), reason :: String.t())
  :: {:ok, :closed} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub/Linear API. Writes context_note "closed: <reason>".

@spec add_to_project(tracker :: :github | :linear, issue_id :: String.t(), project_id :: String.t())
  :: {:ok, :added} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub Projects v2 API or Linear API.
```

### Communication

```elixir
@spec comment_on_issue(repo :: String.t(), issue_number :: integer(), body :: String.t())
  :: {:ok, %{comment_id: integer(), url: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Writes artifact(thread_id, "issue_comment", "github", comment_id, url).

@spec comment_on_pr(repo :: String.t(), pr_number :: integer(), body :: String.t())
  :: {:ok, %{comment_id: integer(), url: String.t()}} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API. Writes artifact(thread_id, "issue_comment", "github", comment_id, url).

@spec reply_in_thread(channel :: String.t(), thread_ts :: String.t(), body :: String.t())
  :: {:ok, :sent} | {:error, :transient | :permanent | :unexpected, term()}
# Calls Slack API. Wedge B stub: logs intent, returns {:error, :permanent, :slack_not_configured}.

@spec post_to_channel(channel :: String.t(), body :: String.t())
  :: {:ok, :sent} | {:error, :transient | :permanent | :unexpected, term()}
# Calls Slack API. Wedge B stub: same as reply_in_thread.
```

### Work Management

```elixir
@spec assign_to_self(issue_id :: String.t(), source :: :github | :linear)
  :: {:ok, :assigned} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub/Linear API to assign the issue to the configured worker identity.

@spec update_issue_status(issue_id :: String.t(), source :: :github | :linear, status :: String.t())
  :: {:ok, :updated} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub/Linear API.

@spec add_label(repo :: String.t(), issue_number :: integer(), label :: String.t())
  :: {:ok, :added} | {:error, :transient | :permanent | :unexpected, term()}
# Calls GitHub API.
```

### Meta

```elixir
@spec write_thread_note(thread_id :: Ecto.UUID.t(), author :: String.t(),
                        note_type :: String.t(), body :: String.t())
  :: {:ok, %Guild.ContextNote{}} | {:error, :unexpected, term()}
# Postgres only. Inserts into context_notes.

@spec update_thread_state(thread_id :: Ecto.UUID.t(), new_state :: atom())
  :: {:ok, %Guild.Thread{}} | {:error, :permanent | :unexpected, term()}
# Postgres only. Validates transition via state machine module, then updates threads.state.
# Returns {:error, :permanent, :illegal_transition} if the transition is not allowed.

@spec log_decision(thread_id :: Ecto.UUID.t(), decision :: %Guild.Worker.Decision{},
                   context_snapshot :: %Guild.Worker.ContextPacket{})
  :: {:ok, %Guild.DecisionLog{}} | {:error, :unexpected, term()}
# Postgres only. Inserts into decisions_log. Called for every decision including :ignore.
```

### Fountain Adapter Mapping

The Fountain adapter (`Guild.Adapters.Fountain`) wraps the five Fountain primitives behind the
adapter interface defined in ADR 0004. The mapping is:

| Guild adapter call | Fountain primitive | When called |
|---|---|---|
| `Guild.Adapters.Fountain.dispatch_conversation(prompt, agent_ref, env, opts)` | `run_worker/2` | Worker returns `:implement`; `claimed → executing` transition |
| `Guild.Adapters.Fountain.send_prompt(conversation_id, prompt)` | `send_prompt/2` | Review feedback delivered to an in-progress Fountain conversation |
| `Guild.Adapters.Fountain.observe_conversation(conversation_id)` | `stream_output/2` | Startup recovery: re-attach to a running conversation to resume streaming |
| `Guild.Adapters.Fountain.get_status(conversation_id)` | `get_status/1` | Startup recovery: check if a conversation is still running or completed |
| `Guild.Adapters.Fountain.terminate_conversation(conversation_id)` | `terminate/1` | Thread transitions to `abandoned`; in-flight Fountain conversation is stopped |

The Fountain conversation ID is stored as an artifact (`artifact_type: "fountain_conversation"`,
`external_id: conversation_id`) so it survives Guild restarts.

---

## Guild.Tasks.ClaimSeed

**Spec:** A one-shot Mix task that seeds a thread for the G2 end-to-end run without requiring the
full claiming loop.

**Mix task vs GenServer:** Mix task. Justification: the full claiming loop (survey → evaluate →
select → claim → begin) is explicitly deferred for Wedge B. A Mix task is a direct, explicit,
manually-invoked operation — the right shape for a controlled one-shot entry point. A GenServer
implies a recurring polling loop that we have explicitly decided not to build yet; adding one now
would be speculative infrastructure that the operating model forbids. A Mix task can be run as
many times as needed during development and testing without any server state to manage.

**Invocation:**
```
mix guild.claim_seed --repo jhgaylor/guild --issue-number 42
```

**Config read:**
- `--repo` (required): GitHub repo in `owner/repo` format
- `--issue-number` (required): the GitHub issue number to seed
- `GITHUB_TOKEN` env var: used by the GitHub API calls within the task
- Application config for `worker_identity` (the GitHub App installation to use)

**What it does:**
1. Fetch the issue from GitHub API using `--repo` + `--issue-number`; fail fast if not found
2. Upsert a `threads` row with `anchor_type: "github_issue"`, `anchor_id: issue.node_id`,
   `anchor_url: issue.html_url`, `state: "unnoticed"`, using `anchor_type + anchor_id` as the
   unique key (idempotent: if thread already exists, skip insert)
3. Call `update_thread_state(thread_id, :noticed)` then `update_thread_state(thread_id, :claimed)`
   via the state machine module (validates both transitions)
4. Call `assign_to_self(issue.number, :github)` to self-assign the issue
5. Call `comment_on_issue(repo, issue.number, "Taking this — will open a PR when ready.")`
6. Insert a seed event into the `events` table (`source: "github"`, `type: "issues.seed"`,
   `thread_id: thread.id`) to anchor the event history
7. Print the resulting `thread_id` to stdout and exit 0

**Error behavior:** any step that returns `{:error, _, reason}` prints the reason and exits 1.
No partial state is cleaned up — re-running the task is idempotent at step 2 because of the
upsert.

---

## ADRs Required Before Implementation

The following architectural choices are not covered by ADR 0002/0003/0004 and would constrain
future work. Each requires a decision record before the implementing PR begins.

**1. Anchor polymorphism strategy**
- Decision to make: how to model the anchor (a GitHub issue, a Linear issue, or a future source)
  in a portable way. Options: discriminator column + `anchor_type`/`anchor_id` pair (current plan);
  separate `github_anchors` / `linear_anchors` tables with a polymorphic join; a single JSONB
  anchor blob. The choice affects foreign key integrity, query patterns, and how easy it is to
  add a new anchor source later.
- Why it needs an ADR: it shapes the `threads` schema and every query that touches the anchor.
  Changing it after migrations exist is a painful refactor.

**2. Thread linkage resolution strategy**
- Decision to make: what rules govern assigning `thread_id` to an incoming event when no explicit
  reference exists (heuristic fallback). Options: always require explicit references and reject
  ambiguous events; run heuristics and flag uncertain links for human confirmation (current plan);
  use an LLM-based linker for ambiguous cases. Affects events table nullability, context-assembly
  correctness, and the worker's ability to act on partially-linked threads.
- Why it needs an ADR: silent mislinks corrupt the thread model. The resolution policy is a
  correctness invariant, not an implementation detail.

**3. Context assembly query strategy**
- Decision to make: how `Guild.ContextAssembly.build/1` queries the thread graph efficiently
  without loading entire thread history into memory. Options: bounded recency window (last N events
  + all human instructions); cursor-based pagination with incremental summarization; pre-computed
  summary rows updated on each event insert. Affects DB query patterns, context packet size, and
  what happens as threads age.
- Why it needs an ADR: the assembly strategy is the primary cost center in the processing loop
  (per `docs/03-context-assembly.md`) and its design constrains the schema (e.g. whether a
  `summary` column belongs on the `threads` table).

**4. Action primitive error taxonomy**
- Decision to make: finalize the three-tier error classification (`:transient`, `:permanent`,
  `:unexpected`) and define which HTTP status codes / Ecto errors / Fountain error responses map
  to each tier. Also: retry parameters (max attempts, backoff curve) for transient errors.
- Why it needs an ADR: the taxonomy is the error-handling contract for every primitive
  implementation and every caller. Ambiguity here means inconsistent recovery behavior across
  primitives, which defeats the audit trail.

**5. decisions_log retention policy**
- Decision to make: how long `context_snapshot` (a full JSONB copy of the context packet) is
  retained. Options: retain indefinitely (simplest; storage cost grows with usage); rolling delete
  (keep last N decisions per thread); archive to cold storage after T days; store snapshot hash
  only after N days (keep the decision but drop the bulky payload).
- Why it needs an ADR: `context_snapshot` will be the largest rows in the database. Without a
  retention policy, the table becomes a storage liability. The policy also determines what
  debuggability looks like for old threads.

---

## Open Questions

These require operator input before the implementing PR can start.

1. **GitHub App credentials for Wedge B**: Which GitHub App installation is used for the single
   static worker identity? Does the operator need to create a new App for Guild, or reuse an
   existing one? What repo permissions are required (contents write, issues write, pull_requests
   write)?

2. **Fountain agent_ref for the first worker**: What `agent_ref` (agent spec / configuration
   identifier) does `dispatch_conversation` pass to Fountain for the implementation worker?
   Who authors the agent spec, and where does it live?

3. **Verification gate trust model**: ADR 0004 notes that the verification requirement moves inside
   the Sprite, and Guild's gate becomes "did the conversation reach `completed` cleanly?" Is that
   signal sufficient for Wedge B, or does Guild need to inspect the conversation output for an
   explicit `verification_passed: true` field before calling `open_pull_request`?

4. **First seeded issue**: What is the GitHub issue number in `jhgaylor/guild` that will be used
   for the G2 end-to-end run? It must exist, have explicit acceptance criteria, and have no
   dependency on sub-issues. Does it exist yet, or does it need to be created before implementation
   begins?

5. **Startup recovery scope**: On Guild restart, should the recovery process re-evaluate *all*
   non-terminal threads, or only threads owned by the configured worker identity? For a single-
   worker Wedge B deployment the answer is the same, but the implementation detail matters when
   multi-worker support is added later.
