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
      body = Jason.encode!(%{choices: [%{message: %{content: json}}]})
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
    test "skips second message from same user in 60s", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      mock_openrouter(bypass, "noise")

      args1 = job_args(%{"event_id" => "evt_rl_1"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args1)
      assert Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_rl_1") != nil

      args2 = job_args(%{"event_id" => "evt_rl_2"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args2)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_rl_2")
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
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
end
