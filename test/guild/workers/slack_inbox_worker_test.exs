defmodule Guild.Workers.SlackInboxWorkerTest do
  use Guild.DataCase, async: false
  use Oban.Testing, repo: Guild.Repo

  import Ecto.Query
  alias Guild.{Repo, Schema}

  @moduletag :capture_log

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :openrouter_api_key, "test-key")
    Application.put_env(:guild, :openrouter_api_url, "http://localhost:#{bypass.port}/v1/chat/completions")
    Application.delete_env(:guild, :slack_bot_user_id)

    {:ok, _} = Repo.insert(%Schema.SlackChannel{channel_id: "C_TEST", enabled: true, default_repo: "owner/repo"})

    on_exit(fn ->
      Application.delete_env(:guild, :openrouter_api_key)
      Application.delete_env(:guild, :openrouter_api_url)
    end)

    {:ok, bypass: bypass}
  end

  defp job_args(overrides \\ %{}) do
    Map.merge(%{
      "event_id" => "evt_#{System.unique_integer([:positive])}",
      "channel_id" => "C_TEST",
      "user_id" => "U123",
      "user_display_name" => "Alice",
      "message_ts" => "1234567890.000001",
      "message_text" => "can you fix the login bug please?"
    }, overrides)
  end

  defp mock_openrouter(bypass, verdict, confidence \\ 0.95) do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      json = Jason.encode!(%{
        verdict: verdict,
        confidence: confidence,
        reasoning: "test reasoning",
        matched_thread_id: nil
      })
      body = Jason.encode!(%{
        model: "openai/gpt-4o-mini",
        choices: [%{message: %{content: json}}],
        usage: %{prompt_tokens: 120, completion_tokens: 30, total_tokens: 150, cost: 0.000123}
      })
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  describe "perform/1 — happy path dry-run" do
    test "inserts slack_inbox_events row with action_taken: dry_run", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      mock_openrouter(bypass, "new_work")

      args = job_args()
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

      event = Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == ^args["event_id"])
      assert event.verdict == "new_work"
      assert event.confidence == 0.95
      assert event.action_taken == "dry_run"
      # Usage metadata captured from the OpenRouter response and persisted on
      # the row so /admin/slack-inbox can show per-classification cost.
      assert event.model == "openai/gpt-4o-mini"
      assert event.prompt_tokens == 120
      assert event.completion_tokens == 30
      assert event.cost_usd == 0.000123
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
    end
  end

  describe "perform/1 — prefilter" do
    test "skips messages shorter than 10 chars (no DB row inserted)" do
      args = job_args(%{"message_text" => "hi", "event_id" => "evt_short"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_short")
    end

    test "skips slash commands (no DB row inserted)" do
      args = job_args(%{"message_text" => "/deploy now", "event_id" => "evt_slash"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_slash")
    end

    test "skips bot's own messages when SLACK_BOT_USER_ID matches" do
      Application.put_env(:guild, :slack_bot_user_id, "U_BOT")
      args = job_args(%{"user_id" => "U_BOT", "event_id" => "evt_bot"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_bot")
    end
  end

  describe "perform/1 — rate limit" do
    test "rate-limited second message records a skipped_rate_limit row (not silent)",
         %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      System.put_env("SLACK_INBOX_RATE_LIMIT_SECONDS", "60")
      mock_openrouter(bypass, "noise")

      args1 = job_args(%{"event_id" => "evt_rl_1"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args1)
      row1 = Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_rl_1")
      assert row1 != nil
      assert row1.verdict == "noise"

      args2 = job_args(%{"event_id" => "evt_rl_2"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args2)
      row2 = Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_rl_2")
      assert row2 != nil
      assert row2.verdict == "skipped_rate_limit"
      assert row2.action_taken == "skipped"
      assert row2.reasoning =~ "60s window"
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
      System.delete_env("SLACK_INBOX_RATE_LIMIT_SECONDS")
    end

    test "SLACK_INBOX_RATE_LIMIT_SECONDS=0 disables the limit entirely",
         %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      System.put_env("SLACK_INBOX_RATE_LIMIT_SECONDS", "0")
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json = Jason.encode!(%{verdict: "noise", confidence: 0.9, reasoning: "x", matched_thread_id: nil})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{choices: [%{message: %{content: json}}]}))
      end)

      args1 = job_args(%{"event_id" => "evt_nolim_1"})
      args2 = job_args(%{"event_id" => "evt_nolim_2"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args1)
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args2)
      assert Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_nolim_1").verdict == "noise"
      assert Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_nolim_2").verdict == "noise"
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
      System.delete_env("SLACK_INBOX_RATE_LIMIT_SECONDS")
    end
  end

  describe "perform/1 — no API key" do
    test "returns :ok without inserting row when OPENROUTER_API_KEY absent" do
      Application.delete_env(:guild, :openrouter_api_key)
      args = job_args(%{"event_id" => "evt_nokey"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_nokey")
    end
  end

  describe "perform/1 — :new_work live action" do
    test "creates GitHub issue, posts Slack reply, inserts action_taken: issue_created", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "false")

      # Configure GitHub test adapter to return a successful create_issue response
      Guild.GitHub.TestAdapter.configure(:create_issue, {:ok, %{"html_url" => "https://github.com/owner/repo/issues/99", "number" => 99}})

      # Configure Slack
      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST_DEFAULT")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/api/chat.postMessage")

      mock_openrouter(bypass, "new_work", 0.95)

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
      assert event.github_issue_url == "https://github.com/owner/repo/issues/99"
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)
      Application.delete_env(:guild, :slack_api_url)
    end
  end

  describe "perform/1 — :refers_to_existing live action" do
    test "inserts Event on matched thread, posts Slack reply, action_taken: reference_reply_posted", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "false")

      # Configure Slack
      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST_DEFAULT")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/api/chat.postMessage")

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
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)
      Application.delete_env(:guild, :slack_api_url)
    end
  end

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
end
