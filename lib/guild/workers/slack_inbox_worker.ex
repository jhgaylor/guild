defmodule Guild.Workers.SlackInboxWorker do
  @moduledoc """
  Oban worker that classifies a top-level Slack message (ADR 0017).
  Queue: :slack_inbox, max_attempts: 2, unique on event_id.
  """

  use Oban.Worker,
    queue: :slack_inbox,
    max_attempts: 2,
    unique: [fields: [:args], keys: [:event_id], period: 300]

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Guild.{Repo, Schema}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "event_id" => event_id,
    "channel_id" => channel_id,
    "user_id" => user_id,
    "user_display_name" => user_display_name,
    "message_ts" => message_ts,
    "message_text" => message_text
  }}) do
    bot_user_id = Application.get_env(:guild, :slack_bot_user_id)

    cond do
      not is_nil(bot_user_id) and bot_user_id != "" and user_id == bot_user_id ->
        Logger.debug("SlackInboxWorker: skipping bot's own message (user_id match)")
        :ok

      String.length(String.trim(message_text)) < 10 ->
        Logger.debug("SlackInboxWorker: skipping short message")
        :ok

      String.starts_with?(String.trim(message_text), "/") ->
        Logger.debug("SlackInboxWorker: skipping slash command")
        :ok

      true ->
        run_classification(event_id, channel_id, user_id, user_display_name, message_ts, message_text)
    end
  end

  defp run_classification(event_id, channel_id, user_id, user_display_name, message_ts, message_text) do
    sixty_seconds_ago = DateTime.add(DateTime.utc_now(), -60, :second)

    rate_limited? =
      Repo.exists?(
        from e in Schema.SlackInboxEvent,
          where:
            e.channel_id == ^channel_id and
            e.user_id == ^user_id and
            e.inserted_at > ^sixty_seconds_ago
      )

    if rate_limited? do
      Logger.debug("SlackInboxWorker: rate limit hit for user #{user_id} in #{channel_id}")
      :ok
    else
      do_classify(event_id, channel_id, user_id, user_display_name, message_ts, message_text)
    end
  end

  defp do_classify(event_id, channel_id, user_id, user_display_name, message_ts, message_text) do
    channel = Repo.get(Schema.SlackChannel, channel_id)
    default_repo = channel && channel.default_repo

    open_states = ["noticed", "claimed", "executing", "pr_open"]
    open_threads =
      Repo.all(
        from t in Schema.Thread,
          where: t.state in ^open_states,
          order_by: [desc: t.updated_at],
          limit: 20,
          select: %{
            id: t.id,
            anchor_id: t.anchor_id,
            summary: t.anchor_id,
            state: t.state,
            updated_at: t.updated_at
          }
      )

    result =
      Guild.SlackInbox.classify(%{
        message: message_text,
        channel_id: channel_id,
        channel_name: channel_id,
        user_display_name: user_display_name || user_id,
        default_repo: default_repo,
        open_threads: open_threads
      })

    case result do
      {:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: matched_thread_id}} ->
        dry_run? = System.get_env("SLACK_INBOX_DRY_RUN", "true") == "true"

        action_taken =
          if dry_run? do
            "dry_run"
          else
            "noise"
          end

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
          action_taken: action_taken,
          github_issue_url: nil
        }

        changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)

        case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id) do
          {:ok, _} -> :ok
          {:error, cs} ->
            Logger.warning("SlackInboxWorker: failed to insert slack_inbox_event: #{inspect(cs.errors)}")
            {:error, :db_insert_failed}
        end

      {:error, :no_api_key} ->
        Logger.warning("SlackInboxWorker: OPENROUTER_API_KEY not set, skipping")
        :ok

      {:error, reason} ->
        attrs = %{
          event_id: event_id,
          channel_id: channel_id,
          user_id: user_id,
          user_display_name: user_display_name,
          message_ts: message_ts,
          message_text: String.slice(message_text, 0, 2000),
          verdict: "failed",
          confidence: 0.0,
          reasoning: "Classification error: #{inspect(reason)}",
          thread_id: nil,
          action_taken: nil
        }

        changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id)

        {:error, reason}
    end
  end
end
