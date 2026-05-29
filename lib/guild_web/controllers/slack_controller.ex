defmodule GuildWeb.SlackController do
  use GuildWeb, :controller

  require Logger

  # Reject requests whose timestamp deviates more than 5 minutes from now.
  @max_age_seconds 300

  @doc """
  Handle POST /slack/commands.

  Auth is via Slack v0 HMAC-SHA256 signature verification only; this route
  must NOT be inside the :auth (basic-auth) pipeline.
  """
  def commands(conn, params) do
    signing_secret = Application.get_env(:guild, :slack_signing_secret)

    if is_nil(signing_secret) or signing_secret == "" do
      Logger.warning("SlackController: SLACK_SIGNING_SECRET not configured, rejecting request")
      forbidden(conn)
    else
      ts = conn |> get_req_header("x-slack-request-timestamp") |> List.first("")
      slack_sig = conn |> get_req_header("x-slack-signature") |> List.first("")
      raw_body = Map.get(conn.private, :raw_body, "")

      with :ok <- verify_timestamp(ts),
           :ok <- verify_signature(signing_secret, ts, raw_body, slack_sig) do
        dispatch(conn, params)
      else
        {:error, reason} ->
          Logger.warning("SlackController: signature verification failed: #{reason}")
          forbidden(conn)
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
