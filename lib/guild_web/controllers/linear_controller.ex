defmodule GuildWeb.LinearController do
  use GuildWeb, :controller

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Guild.{Repo, Schema}

  @doc """
  Handle POST /linear/webhooks.

  Auth is via HMAC-SHA256 signature in the Linear-Signature header, verified
  against :linear_webhook_secret (from LINEAR_WEBHOOK_SECRET env var).
  Fails secure with 403 when the secret is unset or the signature is missing/invalid.
  """
  def webhooks(conn, _params) do
    secret = Application.get_env(:guild, :linear_webhook_secret)

    if is_nil(secret) or secret == "" do
      Logger.warning("LinearController: LINEAR_WEBHOOK_SECRET not configured, rejecting request")
      forbidden(conn)
    else
      raw_body = Map.get(conn.private, :raw_body, "")
      linear_sig = conn |> get_req_header("linear-signature") |> List.first("")

      if linear_sig == "" do
        Logger.warning("LinearController: missing Linear-Signature header")
        forbidden(conn)
      else
        expected = Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw_body), case: :lower)

        valid? =
          byte_size(linear_sig) == byte_size(expected) and
            :crypto.hash_equals(expected, linear_sig)

        if valid? do
          handle_webhook(conn, conn.body_params)
        else
          Logger.warning("LinearController: signature mismatch")
          forbidden(conn)
        end
      end
    end
  end

  defp handle_webhook(conn, body) do
    type = Map.get(body, "type", "unknown")
    event_type = "linear." <> type
    thread_id = resolve_thread_id(body)
    webhook_id = Map.get(body, "webhookId", Ecto.UUID.generate())

    attrs = %{
      source: "linear",
      event_type: event_type,
      occurred_at: DateTime.utc_now(),
      raw_payload: body,
      thread_id: thread_id,
      idempotency_key: "linear:#{type}:#{webhook_id}"
    }

    changeset = %Schema.Event{} |> Schema.Event.changeset(attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, _} ->
        send_resp(conn, 200, "ok")

      {:error, _} ->
        send_resp(conn, 500, "internal error") |> halt()
    end
  end

  # Resolve a thread_id by looking for a GitHub issue number referenced in the
  # Linear payload body/description fields, then matching against Thread.anchor_id.
  defp resolve_thread_id(body) do
    text =
      [
        get_in(body, ["data", "description"]),
        get_in(body, ["data", "body"]),
        get_in(body, ["data", "title"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    regex = ~r/(Closes|Fixes|Refs?) #(\d+)/i

    case Regex.run(regex, text) do
      [_, _keyword, number] ->
        query = from(t in Schema.Thread, where: t.anchor_id == ^number, limit: 1)

        case Repo.one(query) do
          nil -> nil
          thread -> thread.id
        end

      _ ->
        nil
    end
  end

  defp forbidden(conn) do
    conn
    |> send_resp(403, "forbidden")
    |> halt()
  end
end
