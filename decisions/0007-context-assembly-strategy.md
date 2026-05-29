# 0007 — Context assembly: bounded recency window + summarization (G4 update)

**Status:** Accepted (Updated G4)

## Context

At G4 fleet scale, threads accumulate enough context notes that the bounded
recency window (50 events) risks losing important context. The TODO comment
placed in `Guild.ContextAssembly` is now addressed via a summarization hook.

## Decision

**Trigger summarization when a thread's `context_notes` count exceeds 50.**

`Guild.Summarization.maybe_summarize/1` is called during each reconcile cycle
for executing threads. It:

1. Counts active context notes for the thread.
2. No-ops if count <= 50.
3. Over threshold: assembles the thread context via `Guild.ContextAssembly.build/1`,
   POSTs it to Fountain using the existing HTTP adapter
   (`Guild.Adapters.Fountain.dispatch_conversation/4` + `observe_conversation/1`),
   stores the Fountain response as a `ContextNote` with `note_type: "summary"`, and
   marks all previously unsummarized notes as `note_type: "archived"`.

`Guild.ContextAssembly.build/1` is unchanged: it still fetches the last 50 events
and all `human_instruction` notes unconditionally.

## Consequences

- Context notes are bounded in size; summarization prevents unbounded accumulation.
- Human instruction notes are still always included in the context packet.
- Summarization failures are logged and non-fatal; the reconcile loop continues.
- No migration required: the `context_notes` table already supports string `note_type`;
  `summary` and `archived` are added to the application-level allowlist.

## Alternatives considered

- **Pre-computed summary column on threads** — rejected: write-path coupling before
  the shape of a useful summary is understood.
- **Cursor-based pagination** — rejected: significant complexity; summarization is simpler.
- **Summarize on every note insert** — rejected: unnecessary overhead; threshold-based
  batching is more efficient.
