defmodule GuildWeb.SlackController do
  use GuildWeb, :controller

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Guild.{Repo, Schema}

  # Reject requests whose timestamp deviates more than 5 minutes from now.
  @max_age_seconds 300

  @doc """
  Handle POST /slack/commands.

  Auth is via Slack v0 HMAC-SHA256 signature verification only; this route
  must NOT be inside the :auth (basic-auth) pipeline.
  """
  def commands(conn, params) do
    with :ok <- verify_slack_request(conn) do
      dispatch(conn, params)
    else
      {:error, reason} ->
        Logger.warning("SlackController: signature verification failed: #{reason}")
        forbidden(conn)
    end
  end

  @doc """
  Handle POST /slack/interactions (Block Kit interactive payloads).

  Auth is via the same Slack v0 HMAC-SHA256 signature verification.
  Slack sends application/x-www-form-urlencoded with a `payload` JSON field.
  """
  def interactions(conn, params) do
    with :ok <- verify_slack_request(conn) do
      payload_json = Map.get(params, "payload", "{}")
      payload = Jason.decode!(payload_json)
      actions = Map.get(payload, "actions", [])

      Enum.each(actions, fn action ->
        action_id = Map.get(action, "action_id", "")
        value = Map.get(action, "value", "")

        case action_id do
          "guild_hold" ->
            case Guild.Control.hold(value) do
              {:ok, _msg} -> :ok
              {:error, reason} -> Logger.warning("interactions hold error: #{inspect(reason)}")
            end

          "guild_abandon" ->
            case Guild.Control.abandon(value) do
              {:ok, _msg} -> :ok
              {:error, reason} -> Logger.warning("interactions abandon error: #{inspect(reason)}")
            end

          "guild_view" ->
            :ok

          other ->
            Logger.debug("SlackController.interactions: unknown action_id #{inspect(other)}")
        end
      end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{response_action: "clear"}))
    else
      {:error, reason} ->
        Logger.warning("SlackController.interactions: signature verification failed: #{reason}")
        forbidden(conn)
    end
  end

  @doc """
  Handle POST /slack/events (Slack Events API).

  Auth is via the same Slack v0 HMAC-SHA256 signature verification.
  Dispatches:
    - url_verification: returns the challenge value as plain text.
    - reaction_added stop_sign on a message: looks up the slack_message artifact
      and calls Guild.Control.hold/1 on the owning thread.
    - All other events: inserts an Event row with event_type "slack.<type>".
  """
  def events(conn, params) do
    with :ok <- verify_slack_request(conn) do
      dispatch_event(conn, params)
    else
      {:error, reason} ->
        Logger.warning("SlackController.events: signature verification failed: #{reason}")
        forbidden(conn)
    end
  end

  defp dispatch_event(conn, %{"type" => "url_verification", "challenge" => challenge}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, challenge)
  end

  defp dispatch_event(conn, %{"type" => "event_callback", "event" => event} = params) do
    event_type = Map.get(event, "type", "unknown")

    # ADR 0016: every verified Slack event is recorded, including state-driving ones.
    record_slack_event(event_type, params)

    # Then optionally drive state: stop_sign reaction on a Guild-owned slack_message → hold.
    case event do
      %{
        "type" => "reaction_added",
        "reaction" => "stop_sign",
        "item" => %{"type" => "message", "channel" => channel, "ts" => ts}
      } ->
        url = "slack://" <> channel <> "/" <> ts

        case Repo.one(from a in Schema.Artifact, where: a.url == ^url, limit: 1) do
          nil ->
            :ok

          artifact ->
            case Guild.Control.hold(artifact.thread_id) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
            end
        end

      _ ->
        :ok
    end

    send_resp(conn, 200, "")
  end

  defp dispatch_event(conn, params) do
    event_type = get_in(params, ["event", "type"]) || Map.get(params, "type", "unknown")
    record_slack_event(event_type, params)
    send_resp(conn, 200, "")
  end

  # Insert an Event row for a verified Slack event (ADR 0016: record all).
  defp record_slack_event(event_type, raw_payload) do
    attrs = %{
      source: "slack",
      event_type: "slack." <> event_type,
      occurred_at: DateTime.utc_now(),
      raw_payload: raw_payload,
      thread_id: nil,
      idempotency_key: "slack:#{event_type}:#{Ecto.UUID.generate()}"
    }

    changeset = %Schema.Event{} |> Schema.Event.changeset(attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.warning("SlackController.events: failed to insert event: #{inspect(cs.errors)}")
    end
  end

  # Shared HMAC + timestamp verification for all Slack endpoints.
  defp verify_slack_request(conn) do
    signing_secret = Application.get_env(:guild, :slack_signing_secret)

    if is_nil(signing_secret) or signing_secret == "" do
      Logger.warning("SlackController: SLACK_SIGNING_SECRET not configured, rejecting request")
      {:error, "signing secret not configured"}
    else
      ts = conn |> get_req_header("x-slack-request-timestamp") |> List.first("")
      slack_sig = conn |> get_req_header("x-slack-signature") |> List.first("")
      raw_body = Map.get(conn.private, :raw_body, "")

      with :ok <- verify_timestamp(ts) do
        verify_signature(signing_secret, ts, raw_body, slack_sig)
      end
    end
  end

  defp verify_timestamp(ts) do
    case Integer.parse(ts) do
      {timestamp, ""} ->
        now = System.system_time(:second)

        if abs(now - timestamp) > @max_age_seconds do
          {:error, "timestamp too old or too far in future"}
        else
          :ok
        end

      _ ->
        {:error, "invalid or missing X-Slack-Request-Timestamp"}
    end
  end

  defp verify_signature(secret, ts, raw_body, slack_sig) do
    base = "v0:#{ts}:#{raw_body}"
    expected = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    valid? =
      byte_size(slack_sig) == byte_size(expected) and
        :crypto.hash_equals(expected, slack_sig)

    if valid?, do: :ok, else: {:error, "signature mismatch"}
  end

  defp dispatch(conn, params) do
    text = params |> Map.get("text", "") |> String.trim()

    {subcommand, arg} =
      case String.split(text, ~r/\s+/, parts: 2) do
        [sub, rest] -> {sub, String.trim(rest)}
        [sub] -> {sub, ""}
        [] -> {"", ""}
      end

    result =
      case subcommand do
        "hold" -> Guild.Control.hold(arg)
        "resume" -> Guild.Control.resume(arg)
        "abandon" -> Guild.Control.abandon(arg)
        _ -> {:error, :unknown_subcommand}
      end

    message =
      case result do
        {:ok, msg} -> msg
        {:error, :not_found} -> "Thread not found for #{inspect(arg)}."
        {:error, :unknown_subcommand} -> "Unknown subcommand #{inspect(subcommand)}. Use: hold <issue#>, resume <issue#>, or abandon <issue#>."
        {:error, reason} -> "Error: #{inspect(reason)}"
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{response_type: "ephemeral", text: message}))
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    |> halt()
  end
end
