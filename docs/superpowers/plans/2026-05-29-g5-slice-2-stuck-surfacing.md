# G5 Slice 2 — Stuck/Failed Surfacing + Owner Release

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface stuck threads via Slack alerts and UI badges, and release thread ownership when threads reach terminal states.

**Architecture:** Add `last_alerted_at` to threads for alert cooldown; Pass C in reconciler queries stuck threads and alerts; Meta.update_thread_state clears owner on terminal states; index/show templates show stuck indicators.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, Slack Web API (via Guild.Adapters.Slack)

---

### Task 1: Migration — add last_alerted_at to threads

**Files:**
- Create: `priv/repo/migrations/20260529200001_add_last_alerted_at_to_threads.exs`

- [ ] Write migration

```elixir
defmodule Guild.Repo.Migrations.AddLastAlertedAtToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :last_alerted_at, :utc_datetime, null: true
    end
  end
end
```

- [ ] Run: `mix ecto.migrate` (in /tmp/guild)

### Task 2: Update Thread schema

**Files:**
- Modify: `lib/guild/schema/thread.ex`

- [ ] Add field and cast

Add `field :last_alerted_at, :utc_datetime` to schema block.
Add `:last_alerted_at` to cast list in changeset.

### Task 3: Add reconcile Pass C (stuck alerting)

**Files:**
- Modify: `lib/guild/reconcile.ex`

- [ ] Add module constants at top of module:
```elixir
@executing_stuck_after_ms 2 * 3_600_000
@pr_open_stuck_after_ms 48 * 3_600_000
@alert_cooldown_ms 6 * 3_600_000
```

- [ ] Add `pass_c()` call in `do_reconcile/0`

- [ ] Implement pass_c/0 — query stuck threads and alert

### Task 4: Owner release on terminal state

**Files:**
- Modify: `lib/guild/primitives/meta.ex`
- Modify: `lib/guild/reconcile.ex` (Pass B done case)

- [ ] In Meta.update_thread_state: when new_state in [:done, :abandoned], include `owner: nil` in changeset attrs
- [ ] In reconcile Pass B (reconcile_pr_open_thread): reload thread after done transition and ensure owner cleared (handled by Meta)

### Task 5: UI stuck badge on index

**Files:**
- Modify: `lib/guild_web/controllers/thread_html/index.html.heex`

- [ ] Add Stuck column header and inline stuck? computation per thread

### Task 6: UI stuck banner on show

**Files:**
- Modify: `lib/guild_web/live/thread_live.html.heex`

- [ ] Add stuck warning banner at top of show page

### Task 7: Tests

**Files:**
- Modify: `test/guild/reconcile_test.exs`

- [ ] Pass C posts Slack alert for over-threshold :executing thread
- [ ] Pass C skips re-alert when last_alerted_at within cooldown
- [ ] Owner nil'd when thread reaches :done
- [ ] Index/show render stuck indicator for over-threshold thread
