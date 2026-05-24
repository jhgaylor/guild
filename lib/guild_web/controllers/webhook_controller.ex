defmodule GuildWeb.WebhookController do
  use GuildWeb, :controller

  import Plug.Conn
  alias Guild.{Repo, Schema}
  import Ecto.Query, only: [from: 2]

  def receive(conn, _params) do
    raw_body = Map.get(conn.private, :raw_body, "")
    secret = Application.get_env(:guild, :github_webhook_secret, "")

    expected =
      "sha256=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw_body), case: :lower)

    actual = get_req_header(conn, "x-hub-signature-256") |> List.first("")

    valid? =
      byte_size(actual) == byte_size(expected) and :crypto.hash_equals(expected, actual)

    if not valid? do
      conn
      |> send_resp(403, "forbidden")
      |> halt()
    else
      gh_event = get_req_header(conn, "x-github-event") |> List.first("")
      body = conn.body_params
      action = Map.get(body, "action", "")
      event_type = if action == "", do: gh_event, else: "#{gh_event}.#{action}"

      handle_event(conn, event_type, body)
    end
  end

  defp handle_event(conn, "issues.opened", body), do: insert_event(conn, "issues.opened", body)
  defp handle_event(conn, "issues.labeled", body), do: insert_event(conn, "issues.labeled", body)
  defp handle_event(conn, "pull_request.opened", body), do: insert_event(conn, "pull_request.opened", body)

  defp handle_event(conn, "pull_request.closed", body) do
    merged = get_in(body, ["pull_request", "merged"]) == true
    effective_type = if merged, do: "pull_request.merged", else: "pull_request.closed"
    insert_event(conn, effective_type, body)
  end

  defp handle_event(conn, "push", body), do: insert_event(conn, "push", body)
  defp handle_event(conn, _event_type, _body), do: send_resp(conn, 200, "ok")

  defp insert_event(conn, event_type, body) do
    thread_id = resolve_thread_id(body)

    delivery_id =
      get_req_header(conn, "x-github-delivery") |> List.first(Ecto.UUID.generate())

    attrs = %{
      event_type: event_type,
      source: "github",
      actor_id: get_in(body, ["sender", "login"]),
      thread_id: thread_id,
      raw_payload: body,
      occurred_at: DateTime.utc_now(),
      idempotency_key: "github:#{event_type}:#{delivery_id}"
    }

    changeset =
      %Schema.Event{}
      |> Schema.Event.changeset(attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 500, "internal error") |> halt()
    end
  end

  defp resolve_thread_id(body) do
    issue_body = Map.get(body, "body") || ""
    regex = ~r/(Closes|Fixes) #(\d+)/i

    case Regex.run(regex, issue_body) do
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
end
