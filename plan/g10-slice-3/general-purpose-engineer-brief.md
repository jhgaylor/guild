# G10 Slice 3 — New-Work + Reference Actions

Repo: jhgaylor/guild. Branch: g10/slice-3-actions.
Base off: `main` (6f5bdb3 — Slice 2 merged).
TESTS REQUIRED. Read existing files before editing. No scratch docs outside plan/g10-slice-3/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

**Files you own in this slice (do not touch others):**
- `lib/guild/workers/slack_inbox_worker.ex` — extend action dispatch
- `lib/guild/claiming.ex` — add bridge logic
- `test/guild/workers/slack_inbox_worker_test.exs` — extend with new test cases
- `test/guild/claiming_test.exs` — add bridge test (create if it doesn't exist)

Slice 4 runs in parallel and owns `admin_controller.ex`, `router.ex`, and new admin templates. Do not touch those files.

---

## Context

Slice 2 landed the classifier. The worker's non-dry-run path is currently stubbed as
`action_taken: "noise"` for all verdicts. This slice replaces that stub with real actions
and adds the bridge that makes the originating Slack message appear in the `/threads/:id`
timeline.

### Key types from existing code (read before editing):

**`Guild.GitHub.impl().create_issue/6`** — signature:
```elixir
create_issue(repo, title, body, labels, assignees, project_id)
# → {:ok, %{"html_url" => "https://github.com/owner/repo/issues/N", "number" => N, ...}}
# → {:error, tier, reason}
```

**`Guild.Adapters.Slack.post_message/3`** — signature:
```elixir
post_message(channel, text, opts \\ [])
# opts: [thread_ts: "1234567890.000001", blocks: [...]]
# → {:ok, %{channel: c, ts: ts}} | {:ok, :not_configured} | {:error, tier, reason}
```
Pass originating `channel_id` explicitly — do NOT use the default `SLACK_CHANNEL_ID`.
The bot is a member of the channel by definition (Slack only delivers events from channels the bot is in).

**`Guild.Schema.Event.changeset/2`** — requires `:source`, `:event_type`, `:occurred_at`,
`:raw_payload`, `:idempotency_key`. See `lib/guild/schema/event.ex`.

**Thread fields for app_redirect:**
- `thread.slack_thread_ts` — the Slack timestamp of the thread anchor post
- `thread.slack_channel` — the Slack channel ID for the thread anchor post
- App redirect URL: `"https://slack.com/app_redirect?channel=#{channel}&message=#{ts}"`

**`SLACK_INBOX_CONFIDENCE_THRESHOLD`**: read via `System.get_env("SLACK_INBOX_CONFIDENCE_THRESHOLD", "0.7")`, parse to float. Below this threshold: `action_taken: "noise"` regardless of verdict.

---

## 1. Extend `lib/guild/workers/slack_inbox_worker.ex`

### 1a. Replace the stub action dispatch in `do_classify/6`

Read the full current file first. Find this section in `do_classify`:

```elixir
{:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: matched_thread_id}} ->
  dry_run? = System.get_env("SLACK_INBOX_DRY_RUN", "true") == "true"

  action_taken =
    if dry_run? do
      "dry_run"
    else
      "noise"   # ← THIS IS THE STUB
    end

  attrs = %{
    ...
    action_taken: action_taken,
    github_issue_url: nil
  }
  ...
```

Replace this entire `{:ok, ...}` match arm with:

```elixir
{:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: matched_thread_id}} ->
  dry_run? = System.get_env("SLACK_INBOX_DRY_RUN", "true") == "true"
  threshold = System.get_env("SLACK_INBOX_CONFIDENCE_THRESHOLD", "0.7") |> Float.parse() |> elem(0)

  if dry_run? do
    # Dry-run: record classification, no side effects
    attrs = %{
      event_id: event_id,
      channel_id: channel_id,
      user_id: user_id,
      user_display_name: user_display_name,
      message_ts: message_ts,
      message_text: String.slice(message_text, 0, 2000),
      verdict: verdict,
      confidence: confidence,
      reasoning: String.slice(reasoning || "", 0, 500),
      thread_id: if(verdict == "refers_to_existing", do: matched_thread_id, else: nil),
      action_taken: "dry_run",
      github_issue_url: nil
    }
    insert_inbox_event(attrs)
  else
    dispatch_action(
      verdict, confidence, threshold, matched_thread_id,
      event_id, channel_id, user_id, user_display_name,
      message_ts, message_text, default_repo
    )
  end
```

### 1b. Add `dispatch_action/12` private function

Add after `do_classify`:

```elixir
defp dispatch_action(
  verdict, confidence, threshold, matched_thread_id,
  event_id, channel_id, user_id, user_display_name,
  message_ts, message_text, default_repo
) do
  cond do
    # --- :new_work ---
    verdict == "new_work" and confidence >= threshold and not is_nil(default_repo) ->
      title = message_text |> String.split("\n") |> List.first("") |> String.slice(0, 80)
      date_str = Date.utc_today() |> Date.to_iso8601()
      body =
        message_text <>
        "\n\n> @#{user_display_name} in <##{channel_id}> on #{date_str}"

      case Guild.GitHub.impl().create_issue(default_repo, title, body, ["bot-ready"], [], nil) do
        {:ok, %{"html_url" => issue_url, "number" => issue_number}} ->
          # Post threaded confirmation reply to originating Slack message
          reply_text = "Filed as [#{default_repo}##{issue_number}](#{issue_url}). I'll keep you posted in this thread."
          Guild.Adapters.Slack.post_message(channel_id, reply_text, thread_ts: message_ts)

          attrs = %{
            event_id: event_id,
            channel_id: channel_id,
            user_id: user_id,
            user_display_name: user_display_name,
            message_ts: message_ts,
            message_text: String.slice(message_text, 0, 2000),
            verdict: verdict,
            confidence: confidence,
            reasoning: "new_work action taken",
            thread_id: nil,  # backfilled by bridge when ClaimWorker creates thread
            action_taken: "issue_created",
            github_issue_url: issue_url
          }
          insert_inbox_event(attrs)

        {:error, tier, reason} ->
          Logger.warning("SlackInboxWorker: GitHub create_issue failed: #{tier} #{inspect(reason)}")
          attrs = %{
            event_id: event_id,
            channel_id: channel_id,
            user_id: user_id,
            user_display_name: user_display_name,
            message_ts: message_ts,
            message_text: String.slice(message_text, 0, 2000),
            verdict: verdict,
            confidence: confidence,
            reasoning: "GitHub create_issue failed: #{inspect(reason)}",
            thread_id: nil,
            action_taken: "failed",
            github_issue_url: nil
          }
          insert_inbox_event(attrs)
      end

    # :new_work but no default_repo configured
    verdict == "new_work" and confidence >= threshold and is_nil(default_repo) ->
      Logger.warning("SlackInboxWorker: :new_work verdict but no default_repo for channel #{channel_id}")
      attrs = base_attrs(event_id, channel_id, user_id, user_display_name, message_ts, message_text,
                         verdict, confidence, "no default_repo configured", nil, "noise", nil)
      insert_inbox_event(attrs)

    # --- :refers_to_existing ---
    verdict == "refers_to_existing" and confidence >= threshold and not is_nil(matched_thread_id) ->
      case Repo.get(Schema.Thread, matched_thread_id) do
        nil ->
          Logger.warning("SlackInboxWorker: matched_thread_id #{matched_thread_id} not found in DB")
          attrs = base_attrs(event_id, channel_id, user_id, user_display_name, message_ts, message_text,
                             verdict, confidence, "matched thread not found", nil, "noise", nil)
          insert_inbox_event(attrs)

        thread ->
          # Record Event on matched thread
          event_attrs = %{
            source: "slack",
            event_type: "slack.reference",
            occurred_at: DateTime.utc_now(),
            raw_payload: %{
              channel_id: channel_id,
              user_id: user_id,
              message_ts: message_ts,
              message_text: String.slice(message_text, 0, 2000)
            },
            thread_id: thread.id,
            idempotency_key: "slack:reference:#{event_id}"
          }
          changeset = Schema.Event.changeset(%Schema.Event{}, event_attrs)
          Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key)

          # Post threaded reply to originating Slack message
          reply_text =
            if thread.slack_thread_ts && thread.slack_channel do
              app_url = "https://slack.com/app_redirect?channel=#{thread.slack_channel}&message=#{thread.slack_thread_ts}"
              "@#{user_display_name} — this looks like ongoing work: [Open in Slack](#{app_url}). Continuing there."
            else
              issue_url = "https://github.com/#{thread.anchor_id}"
              "@#{user_display_name} — this looks like ongoing work on [#{thread.anchor_id}](#{issue_url})."
            end
          Guild.Adapters.Slack.post_message(channel_id, reply_text, thread_ts: message_ts)

          attrs = base_attrs(event_id, channel_id, user_id, user_display_name, message_ts, message_text,
                             verdict, confidence, "reference action taken", matched_thread_id,
                             "reference_reply_posted", nil)
          insert_inbox_event(attrs)
      end

    # :refers_to_existing but no matched thread or confidence below threshold
    # Also catches: :noise, or anything below threshold
    true ->
      attrs = base_attrs(event_id, channel_id, user_id, user_display_name, message_ts, message_text,
                         verdict, confidence,
                         if(confidence < threshold, do: "confidence below threshold (#{confidence} < #{threshold})", else: "noise"),
                         nil, "noise", nil)
      insert_inbox_event(attrs)
  end
end

defp base_attrs(event_id, channel_id, user_id, user_display_name, message_ts, message_text,
                verdict, confidence, reasoning, thread_id, action_taken, github_issue_url) do
  %{
    event_id: event_id,
    channel_id: channel_id,
    user_id: user_id,
    user_display_name: user_display_name,
    message_ts: message_ts,
    message_text: String.slice(message_text, 0, 2000),
    verdict: verdict,
    confidence: confidence,
    reasoning: String.slice(reasoning || "", 0, 500),
    thread_id: thread_id,
    action_taken: action_taken,
    github_issue_url: github_issue_url
  }
end

defp insert_inbox_event(attrs) do
  changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)
  case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id) do
    {:ok, _} -> :ok
    {:error, cs} ->
      Logger.warning("SlackInboxWorker: failed to insert slack_inbox_event: #{inspect(cs.errors)}")
      {:error, :db_insert_failed}
  end
end
```

**Note on `thread.anchor_id` for the GitHub fallback URL:** `anchor_id` is the issue number as a string (e.g. `"42"`), not `"repo/owner#42"`. The fallback link in refers_to_existing needs the repo too. Load it from the thread's anchor differently, or just link to the GitHub issue by constructing from `default_repo + "#" + anchor_id`. Since `default_repo` is in scope... it isn't though. A simpler fallback: just show the thread without a link: `"@#{user_display_name} — this looks like ongoing work on thread #{String.slice(thread.id, 0, 8)}."` OR look up the thread's anchor_url if set. Check `thread.anchor_url` — if set, use it; otherwise fall back to the plain message. Whatever you do, keep it simple and correct.

---

## 2. Bridge step in `lib/guild/claiming.ex`

### Goal

When `ClaimWorker` creates a work thread for a GitHub issue that was originally
filed from Slack (via `:new_work` action), the `slack_inbox_events` row has
`github_issue_url` set but `thread_id = nil`. This bridge:
1. Looks up the `slack_inbox_events` row by `github_issue_url`
2. Backfills `thread_id = new_thread.id`
3. Inserts an `Event` row on the new thread (`source: "slack"`, `event_type: "slack.message"`)
   so the originating Slack message appears first in `/threads/:id`

### Where to add it

In `claim_issue/3`, extend the `with` chain. After `{:ok, thread}` is established from
`claim_with_lock`, add a bridge step. Read the full `claim_issue/3` function before editing.

The current `with` chain is:
```elixir
with {:ok, issue} <- Guild.GitHub.impl().get_issue(repo, issue_number),
     {:ok, thread} <- claim_with_lock(issue_number, worker_id),
     {:ok, _event} <- insert_seed_event(repo, issue_number, thread),
     {:ok, conv_id} <- dispatch_and_store(thread, repo, issue_number, worker_id),
     {:ok, thread} <- transition_to_executing(thread) do
```

Add the bridge as a private function called from inside the `with` block's success path
(after `transition_to_executing` succeeds), NOT as another `with` step (bridge failure
should log-and-continue, not abort claiming):

```elixir
with {:ok, issue} <- Guild.GitHub.impl().get_issue(repo, issue_number),
     {:ok, thread} <- claim_with_lock(issue_number, worker_id),
     {:ok, _event} <- insert_seed_event(repo, issue_number, thread),
     {:ok, conv_id} <- dispatch_and_store(thread, repo, issue_number, worker_id),
     {:ok, thread} <- transition_to_executing(thread) do

  # Bridge: if this issue was originally filed from Slack, link the thread and
  # backfill slack_inbox_events so the Slack message appears on /threads/:id.
  bridge_slack_inbox_event(repo, issue_number, thread)

  # ... rest of existing success body (Linear create_issue call, etc.)
```

### `bridge_slack_inbox_event/3` private function

Add at the bottom of `lib/guild/claiming.ex`:

```elixir
# Bridge: look up a slack_inbox_events row for this GitHub issue URL,
# backfill thread_id, and insert a slack.message Event on the new thread
# so the originating Slack message appears in /threads/:id timeline.
defp bridge_slack_inbox_event(repo, issue_number, thread) do
  github_issue_url = "https://github.com/#{repo}/issues/#{issue_number}"

  case Repo.one(
    from e in Guild.Schema.SlackInboxEvent,
      where: e.github_issue_url == ^github_issue_url and is_nil(e.thread_id),
      limit: 1
  ) do
    nil ->
      # Not filed from Slack — nothing to bridge
      :ok

    inbox_event ->
      # 1. Backfill thread_id on slack_inbox_events
      inbox_event
      |> Ecto.Changeset.change(thread_id: thread.id)
      |> Repo.update()

      # 2. Insert Event row so Slack message appears in thread timeline
      event_attrs = %{
        source: "slack",
        event_type: "slack.message",
        occurred_at: inbox_event.inserted_at,
        raw_payload: %{
          channel_id: inbox_event.channel_id,
          user_id: inbox_event.user_id,
          user_display_name: inbox_event.user_display_name,
          message_ts: inbox_event.message_ts,
          message_text: inbox_event.message_text
        },
        thread_id: thread.id,
        idempotency_key: "slack:bridge:#{inbox_event.event_id}"
      }

      changeset = Guild.Schema.Event.changeset(%Guild.Schema.Event{}, event_attrs)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
        {:ok, _} ->
          Logger.info("Claiming: bridged Slack inbox event #{inbox_event.event_id} to thread #{thread.id}")
          :ok
        {:error, cs} ->
          Logger.warning("Claiming: failed to insert bridge Event: #{inspect(cs.errors)}")
          :ok  # non-fatal — claiming succeeds regardless
      end
  end
end
```

Add `import Ecto.Query, only: [from: 2]` to the module if not already present (check the top of the file — it likely is since the file already has DB queries).

Also add `alias Guild.Schema.SlackInboxEvent` to the aliases block at the top of the module, or use the fully-qualified name `Guild.Schema.SlackInboxEvent` in the query.

---

## 3. Tests

### 3a. Extend `test/guild/workers/slack_inbox_worker_test.exs`

Read the existing file. It uses `use Oban.Testing, repo: Guild.Repo` and `perform_job/2`.
Add new describe blocks. The test setup already inserts a SlackChannel with `default_repo: "owner/repo"`.

You need Bypass mocks for both GitHub and Slack. The GitHub adapter is configured via
`Application.put_env(:guild, :github_adapter, ...)` in non-test environments. In test,
`Guild.GitHub.impl()` returns `Guild.GitHub.TestAdapter`. Look at how existing tests
handle GitHub calls — check `test/support/` for a test adapter or mock setup.

If `Guild.GitHub.TestAdapter` (at `lib/guild/github/test_adapter.ex`) supports
`set_response/2` or similar, use that. Otherwise, check `config/test.exs` for
how the GitHub adapter is configured in tests. Read those files before writing tests.

For Slack: use Bypass to mock the Slack API (same pattern as `Guild.ReleaseTest`):
```elixir
Application.put_env(:guild, :slack_bot_token, "xoxb-test")
Application.put_env(:guild, :slack_channel_id, "C_TEST_DEFAULT")
Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/api/chat.postMessage")
```

**Test: `:new_work` live path creates GitHub issue + Slack reply + DB row**
```elixir
describe "perform/1 — :new_work live action" do
  test "creates GitHub issue, posts Slack reply, inserts action_taken: issue_created", %{bypass: bypass} do
    System.put_env("SLACK_INBOX_DRY_RUN", "false")
    # OpenRouter returns :new_work
    mock_openrouter(bypass, "new_work", 0.95)

    # GitHub create_issue mock
    # (read test adapter setup — if TestAdapter.set_response exists, use it;
    #  otherwise Bypass a second port for GitHub API)
    # GitHub mock should return: %{"html_url" => "https://github.com/owner/repo/issues/99", "number" => 99}

    # Slack mock: expect a chat.postMessage call
    Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["thread_ts"] == "1234567890.000001"
      assert decoded["channel"] == "C_TEST"
      assert String.contains?(decoded["text"], "Filed as")
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"channel":"C_TEST","ts":"111.222"}))
    end)

    args = job_args()
    assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

    event = Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == ^args["event_id"])
    assert event.action_taken == "issue_created"
    assert event.github_issue_url != nil
  after
    System.delete_env("SLACK_INBOX_DRY_RUN")
  end
end
```

**Test: `:refers_to_existing` live path inserts Event + posts Slack reply**
```elixir
describe "perform/1 — :refers_to_existing live action" do
  test "inserts Event on matched thread, posts Slack reply, action_taken: reference_reply_posted", %{bypass: bypass} do
    System.put_env("SLACK_INBOX_DRY_RUN", "false")

    # Insert a real thread to match against
    {:ok, thread} = Repo.insert(
      Schema.Thread.changeset(%Schema.Thread{}, %{
        anchor_type: "github_issue",
        anchor_id: "42",
        state: "executing",
        slack_thread_ts: "999.000",
        slack_channel: "C_WORK"
      })
    )

    # OpenRouter returns :refers_to_existing with matched thread UUID
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      json = Jason.encode!(%{
        verdict: "refers_to_existing",
        confidence: 0.90,
        reasoning: "references existing work",
        matched_thread_id: thread.id
      })
      Plug.Conn.resp(conn, 200, Jason.encode!(%{choices: [%{message: %{content: json}}]}))
    end)

    # Slack mock: expect reply
    Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["thread_ts"] == "1234567890.000001"
      assert String.contains?(decoded["text"], "Open in Slack")
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"channel":"C_TEST","ts":"111.222"}))
    end)

    args = job_args(%{"event_id" => "evt_refers"})
    assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

    inbox = Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_refers")
    assert inbox.action_taken == "reference_reply_posted"
    assert inbox.thread_id == thread.id

    # Event row inserted on matched thread
    ref_event = Repo.one(from e in Schema.Event,
      where: e.thread_id == ^thread.id and e.event_type == "slack.reference")
    assert ref_event != nil
  after
    System.delete_env("SLACK_INBOX_DRY_RUN")
  end
end
```

**Test: `:noise` live path — no side effects**
```elixir
describe "perform/1 — :noise live action" do
  test "inserts action_taken: noise, no GitHub or Slack calls", %{bypass: bypass} do
    System.put_env("SLACK_INBOX_DRY_RUN", "false")
    mock_openrouter(bypass, "noise", 0.95)
    # No Bypass expectations for GitHub or Slack — if called, Bypass will error

    args = job_args(%{"event_id" => "evt_noise_live"})
    assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

    inbox = Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_noise_live")
    assert inbox.action_taken == "noise"
  after
    System.delete_env("SLACK_INBOX_DRY_RUN")
  end
end
```

**Test: confidence below threshold — action_taken: noise**
```elixir
describe "perform/1 — confidence below threshold" do
  test "action_taken: noise when confidence < threshold regardless of verdict", %{bypass: bypass} do
    System.put_env("SLACK_INBOX_DRY_RUN", "false")
    System.put_env("SLACK_INBOX_CONFIDENCE_THRESHOLD", "0.8")
    mock_openrouter(bypass, "new_work", 0.65)  # below 0.8 threshold

    args = job_args(%{"event_id" => "evt_lowconf"})
    assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

    inbox = Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_lowconf")
    assert inbox.action_taken == "noise"
  after
    System.delete_env("SLACK_INBOX_DRY_RUN")
    System.delete_env("SLACK_INBOX_CONFIDENCE_THRESHOLD")
  end
end
```

### 3b. Bridge test — `test/guild/claiming_test.exs`

Check if this file exists. If it does, add to it. If not, create it.

```elixir
defmodule Guild.ClaimingTest do
  use Guild.DataCase, async: false

  import Ecto.Query
  alias Guild.{Repo, Schema}

  # The GitHub adapter in test env — check config/test.exs for what Guild.GitHub.impl() returns
  # and how to set up responses. Typically: use Guild.GitHub.TestAdapter.set_response/2.

  describe "bridge_slack_inbox_event via claim_issue" do
    test "slack_inbox_events row gets thread_id backfilled and Event inserted" do
      # Set up a slack_inbox_events row as if SlackInboxWorker created it for a :new_work action
      issue_url = "https://github.com/owner/repo/issues/77"
      {:ok, inbox_event} = Repo.insert(
        Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, %{
          event_id: "evt_bridge_test",
          channel_id: "C_BRIDGE",
          user_id: "U_BRIDGE",
          message_ts: "1234567890.000099",
          message_text: "can you add dark mode?",
          verdict: "new_work",
          confidence: 0.92,
          reasoning: "direct task request",
          action_taken: "issue_created",
          github_issue_url: issue_url,
          thread_id: nil
        })
      )
      assert inbox_event.thread_id == nil

      # Configure GitHub test adapter to return a fake issue for get_issue/2
      # (check how existing claim tests set this up — TestAdapter.set_response or similar)
      # ...

      # Run claim_issue — this should bridge the inbox_event
      # (In test env, Fountain dispatch may be stubbed — check existing tests for pattern)
      # ...

      # After claiming: slack_inbox_events.thread_id is backfilled
      updated_inbox = Repo.get_by!(Schema.SlackInboxEvent, event_id: "evt_bridge_test")
      assert updated_inbox.thread_id != nil

      # Event row inserted on the new thread with event_type: "slack.message"
      bridge_event = Repo.one(
        from e in Schema.Event,
          where:
            e.thread_id == ^updated_inbox.thread_id and
            e.event_type == "slack.message" and
            e.source == "slack"
      )
      assert bridge_event != nil
      assert get_in(bridge_event.raw_payload, ["channel_id"]) == "C_BRIDGE"
    end
  end
end
```

**Before writing the bridge test**, read `lib/guild/github/test_adapter.ex` and any
existing `test/guild/claiming_test.exs` to understand how the test environment handles
`get_issue`, Fountain dispatch, etc. The bridge is non-fatal — if Fountain dispatch
fails in tests, that's expected and may cause the with-chain to short-circuit before
the bridge runs. Write the test at the level that exercises the bridge most cleanly
(possibly by calling `bridge_slack_inbox_event` directly via `send/3` if it's private, 
or by stubbing all the `with` dependencies). Use your judgment.

---

## Implementation order

1. Read `lib/guild/workers/slack_inbox_worker.ex` in full — understand current structure
2. Read `lib/guild/github/test_adapter.ex` — understand how to mock GitHub in tests
3. Read `lib/guild/claiming.ex` in full
4. Edit `slack_inbox_worker.ex` — replace stub, add `dispatch_action`, `base_attrs`, `insert_inbox_event`
5. Edit `claiming.ex` — add `bridge_slack_inbox_event/3`, call it in success path
6. Extend `test/guild/workers/slack_inbox_worker_test.exs` with new describe blocks
7. Write/extend `test/guild/claiming_test.exs` bridge test
8. `mix test --exclude e2e` — all green
9. Open PR against `main`. Title: `feat(g10/s3): new-work + reference actions + bridge`. Request review from jhgaylor.

Do not modify `ROADMAP.md`.
