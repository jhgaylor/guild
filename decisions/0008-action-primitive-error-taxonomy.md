# 0008 — Action primitive error taxonomy: three-tier typed returns

**Status:** Accepted

## Context

Guild's action primitives call GitHub, Fountain, and Postgres. Each call can fail in structurally different ways — rate limits, permission errors, network timeouts, unexpected response shapes, and unhandled exceptions. The primitives need a consistent error contract so the worker runtime, the state machine, and the audit trail all behave predictably without ad-hoc error handling scattered across 24 call sites.

## Decision

**Three-tier error taxonomy.** Every action primitive returns `{:ok, result}` or one of:

```elixir
{:error, :transient, reason}   # retry eligible
{:error, :permanent, reason}   # thread → blocked
{:error, :unexpected, reason}  # thread → abandoned + escalate
```

**Retry semantics for `:transient`:** maximum 3 attempts, exponential backoff at 2^n seconds (2 s, 4 s, 8 s). After exhausting retries, the error is promoted to `:permanent`.

**Tier mapping table — canonical.** All error shapes must map to one of these tiers. New error shapes must be added to this table when introduced.

| Error shape | Tier |
|---|---|
| HTTP 429 (rate limit) | `:transient` |
| HTTP 5xx from GitHub or Fountain | `:transient` |
| Ecto `{:error, :timeout}` | `:transient` |
| Network timeout / connection refused | `:transient` |
| HTTP 404 (resource not found) | `:permanent` |
| HTTP 403 (permission denied) | `:permanent` |
| HTTP 422 (validation error from GitHub) | `:permanent` |
| Ecto changeset error | `:permanent` |
| Fountain `{:error, :conversation_not_found}` | `:permanent` |
| Any `raise` / unhandled exception caught by `rescue` | `:unexpected` |
| Fountain returns unexpected status atom | `:unexpected` |
| Ecto returns shape not in typespec | `:unexpected` |

**Prohibition:** silent error suppression (`rescue _ -> :ok`) is prohibited. Every `rescue` block must either re-raise or return a typed error tuple. This rule is enforced by code review; a Credo check should be added when the rule is repeatedly violated.

## Consequences

- Error handling is a single consistent pattern across all action primitives; the runtime's error handler is one `case` on a three-element tuple, not a grow-without-bound dispatch table.
- The audit trail can record tier + reason for every failure without special-casing per primitive.
- Engineers must classify new error shapes into the table above; the table is a maintenance artifact. This is the correct artifact to maintain — it makes implicit knowledge explicit.
- The three-tier structure preserves the distinction between "a human can fix this" (`:permanent`), "retry and it may resolve" (`:transient`), and "something is wrong with our code or contracts" (`:unexpected`). Collapsing to two tiers would lose that signal.

## Alternatives considered

- **Two tiers** (retry / no-retry) — rejected: loses the distinction between a permanent external condition (e.g. 403) and a contract violation in our own code (e.g. unexpected Ecto shape). The `:unexpected` tier is essential for surfacing bugs rather than silently blocking threads.
- **Per-module custom exception types** (one exception module per primitive) — rejected: makes the runtime error handler a `case` statement that grows without bound as primitives are added; the common tier structure is lost across the module boundary.
