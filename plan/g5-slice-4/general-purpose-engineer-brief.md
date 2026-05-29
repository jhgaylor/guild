# G5 Slice 4 — Worker-Conversation Lifecycle

Repo: jhgaylor/guild. Branch: g5/slice-4-conv-lifecycle.
Defer the operator digest entirely (G6). Implement worker-conv termination ONLY.
Do NOT create scratch/planning docs outside plan/g5-slice-4/.
## lib/guild/reconcile.ex — Pass D
Add pass_d() to do_reconcile alongside pass_a/b/c. Query threads where state in
["done","abandoned"] that have a fountain_conversation Artifact. For each thread:
  1. Call Guild.Adapters.Fountain.get_status(conv_id) (or equivalent — read the
     adapter first to find the real function name).
  2. If status is already terminated/completed, skip (idempotent — no-op).
  3. Otherwise call Guild.Adapters.Fountain.terminate_conversation(conv_id) (or
     the real termination function — add terminate_conversation/1 if it doesn't
     exist, wrapping the Fountain DELETE/terminate endpoint).
  4. Wrap in try/rescue: on any error, Logger.warning and move on (never crash).
Pass D must never crash the reconcile loop.
## lib/guild_web/live/thread_live.ex + .html.heex
On mount, for threads that have a fountain_conversation Artifact: call
Guild.Adapters.Fountain.get_status/1 and assign conv_status to socket.
In the template, display conv status (running/idle/terminated) next to the
artifact entry. Handle errors gracefully: show "unknown" or dash if call fails.
## lib/guild/adapters/fountain.ex
Read the existing module first. If terminate_conversation/1 does not exist, add
it. If get_status/1 does not exist, add it. Reuse existing HTTP/auth patterns.
## Tests
test/guild/reconcile_test.exs Pass D scenarios using Bypass or TestAdapter:
(1) Thread in :done with live fountain_conversation -> terminate called.
(2) Thread in :done with already-terminated conv -> terminate NOT called (idempotent).
(3) Fountain error during Pass D -> warning logged, no crash, reconcile continues.
mix test --exclude e2e green. PR open on g5/slice-4-conv-lifecycle.
