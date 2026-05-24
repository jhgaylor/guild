defmodule GuildWeb.WebhookController do
  use GuildWeb, :controller

  import Plug.Conn
  alias Guild.{Repo, Schema}
  import Ecto.Query, only: [from: 2]

  @handled_events ~w(issues.opened issues.labeled pull_request.opened pull_request.merged push)

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
      event_type = get_req_header(conn, "x-github-event") |> List.first("")
      body = conn.body_params

      if event_type in @handled_events do
        insert_event(conn, event_type, body)
      else
        send_resp(conn, 200, "ok")
      end
    end
  end

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

    %Schema.Event{}
    |> Schema.Event.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key)

    send_resp(conn, 200, "ok")
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
