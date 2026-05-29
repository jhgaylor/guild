# G5 Slice 2 — Stuck/Failed Surfacing + threads.owner Release

Repo: jhgaylor/guild. Branch: g5/slice-2-stuck-surfacing. ADR 0014 accepted.
Schema modules at lib/guild/schema/ (singular). Read existing code before editing.
## Migration + lib/guild/schema/thread.ex
New migration: add last_alerted_at :utc_datetime, null: true to threads table.
Update lib/guild/schema/thread.ex: add field :last_alerted_at, :utc_datetime and
cast it in changeset.
## lib/guild/reconcile.ex — Pass C
Add @executing_stuck_after_ms (2 * 3_600_000) and @pr_open_stuck_after_ms
(48 * 3_600_000) and @alert_cooldown_ms (6 * 3_600_000) module constants.
Add pass_c() called from do_reconcile alongside pass_a/pass_b. Pass C:
  Query threads where state in ["executing","pr_open"] AND updated_at <
  DateTime.utc_now() - threshold for that state AND (last_alerted_at IS NULL
  OR last_alerted_at < DateTime.utc_now() - @alert_cooldown_ms).
  For each stuck thread: call Guild.Adapters.Slack.post_message/2 with a message
  including thread id, state, and age (graceful no-op if Slack unconfigured).
  Then Repo.update! thread: set last_alerted_at = DateTime.utc_now().
## Owner release on terminal state
When a thread transitions to :done or :abandoned, clear threads.owner (set nil).
Wire into reconcile Pass B (:pr_open→:done) and anywhere :abandoned is set.
Use Repo.update! with Thread.changeset(thread, %{owner: nil}). Idempotent.
## UI badges (read existing templates before editing)
threads index template: add a stuck indicator/badge column — thread is "stuck" by
the same rule (state in [:executing,:pr_open], updated_at older than threshold).
Compute in the LiveView assigns or inline in template using DateTime.diff.
/threads/:id show template: add a stuck warning banner at the top using same rule.
## Tests + Done-when
test/guild/reconcile_test.exs: (1) Pass C posts Slack alert for over-threshold
:executing thread. (2) Pass C skips re-alert when last_alerted_at within cooldown.
(3) owner nil'd when thread reaches :done. Additional: index/show render stuck
indicator for over-threshold thread. mix test --exclude e2e green. PR open on branch.
