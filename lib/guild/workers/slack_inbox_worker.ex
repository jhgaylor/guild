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
    window_seconds = rate_limit_window_seconds()

    rate_limited? =
      window_seconds > 0 and
        Repo.exists?(
          from e in Schema.SlackInboxEvent,
            where:
              e.channel_id == ^channel_id and
              e.user_id == ^user_id and
              e.inserted_at > ^DateTime.add(DateTime.utc_now(), -window_seconds, :second)
        )

    if rate_limited? do
      Logger.debug("SlackInboxWorker: rate limit hit for user #{user_id} in #{channel_id} (window #{window_seconds}s)")
      record_skip(event_id, channel_id, user_id, user_display_name, message_ts, message_text, window_seconds)
    else
      do_classify(event_id, channel_id, user_id, user_display_name, message_ts, message_text)
    end
  end

  defp rate_limit_window_seconds do
    case System.get_env("SLACK_INBOX_RATE_LIMIT_SECONDS") do
      nil -> 5
      "" -> 5
      raw ->
        case Integer.parse(raw) do
          {n, _} when n >= 0 -> n
          _ -> 5
        end
    end
  end

  defp record_skip(event_id, channel_id, user_id, user_display_name, message_ts, message_text, window_seconds) do
    attrs = %{
      event_id: event_id,
      channel_id: channel_id,
      user_id: user_id,
      user_display_name: user_display_name,
      message_ts: message_ts,
      message_text: String.slice(message_text || "", 0, 2000),
      verdict: "skipped_rate_limit",
      confidence: 0.0,
      reasoning: "Skipped: another classification from this user in #{channel_id} within #{window_seconds}s window",
      thread_id: nil,
      action_taken: "skipped",
      github_issue_url: nil
    }

    changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id) do
      {:ok, _} -> :ok
      {:error, cs} ->
        Logger.warning("SlackInboxWorker: failed to insert skip row: #{inspect(cs.errors)}")
        :ok
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
              thread_id: nil,
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
                anchor_ref =
                  if thread.anchor_url do
                    "[#{thread.anchor_id}](#{thread.anchor_url})"
                  else
                    "thread #{String.slice(thread.id, 0, 8)}"
                  end
                "@#{user_display_name} — this looks like ongoing work on #{anchor_ref}."
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
end
