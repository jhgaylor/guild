defmodule GuildWeb.WebhookController do
  use GuildWeb, :controller

  require Logger

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
      {:ok, _} ->
        maybe_claim_from_event(event_type, body)
        send_resp(conn, 200, "ok")

      {:error, _} ->
        send_resp(conn, 500, "internal error") |> halt()
    end
  end

  defp maybe_claim_from_event("issues.opened", body) do
    labels = get_in(body, ["issue", "labels"]) || []
    label_names = Enum.map(labels, & &1["name"])

    if "bot-ready" in label_names do
      repo = get_in(body, ["repository", "full_name"])
      issue_number = get_in(body, ["issue", "number"])
      maybe_claim(repo, issue_number)
    end
  end

  defp maybe_claim_from_event("issues.labeled", body) do
    label_name = get_in(body, ["label", "name"])

    if label_name == "bot-ready" do
      repo = get_in(body, ["repository", "full_name"])
      issue_number = get_in(body, ["issue", "number"])
      maybe_claim(repo, issue_number)
    end
  end

  defp maybe_claim_from_event(_event_type, _body), do: :ok

  defp maybe_claim(repo, issue_number) do
    claimed_states = ["claimed", "executing", "pr_open"]
    anchor_id = to_string(issue_number)

    already_claimed =
      Repo.one(
        from t in Schema.Thread,
          where:
            t.anchor_type == "github_issue" and
              t.anchor_id == ^anchor_id and
              t.state in ^claimed_states,
          limit: 1
      )

    if already_claimed do
      Logger.info("Thread already claimed for issue #{repo}##{issue_number}, skipping")
    else
      if Application.get_env(:guild, :claim_async, true) do
        Task.start(fn ->
          case Guild.Claiming.claim_issue(repo, issue_number) do
            {:ok, %{thread: t, fountain_conv_id: id}} ->
              Logger.info("Claimed issue #{repo}##{issue_number}: thread=#{t.id} conv=#{id}")

            {:error, reason} ->
              Logger.error("Failed to claim issue #{repo}##{issue_number}: #{inspect(reason)}")
          end
        end)
      else
        case Guild.Claiming.claim_issue(repo, issue_number) do
          {:ok, %{thread: t, fountain_conv_id: id}} ->
            Logger.info("Claimed issue #{repo}##{issue_number}: thread=#{t.id} conv=#{id}")

          {:error, reason} ->
            Logger.error("Failed to claim issue #{repo}##{issue_number}: #{inspect(reason)}")
        end
      end
    end
  end

  defp resolve_thread_id(body) do
    issue_body =
      Map.get(body, "body") ||
        get_in(body, ["pull_request", "body"]) ||
        get_in(body, ["issue", "body"]) ||
        ""

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
