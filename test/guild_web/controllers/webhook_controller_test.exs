defmodule GuildWeb.WebhookControllerTest do
  use GuildWeb.ConnCase, async: false

  import Ecto.Query
  alias Guild.{Repo, Schema}

  @test_secret "test_secret"

  defp compute_sig(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  setup do
    Application.put_env(:guild, :github_webhook_secret, @test_secret)
    on_exit(fn -> Application.delete_env(:guild, :github_webhook_secret) end)
    :ok
  end

  defp signed_conn(conn, body, event_type, extra_headers \\ []) do
    sig = compute_sig(@test_secret, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", sig)
    |> put_req_header("x-github-event", event_type)
    |> put_req_header("x-github-delivery", Ecto.UUID.generate())
    |> then(fn c ->
      Enum.reduce(extra_headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    end)
    |> post(~p"/api/webhooks/github", body)
  end

  describe "HMAC validation" do
    test "valid HMAC + issues.opened returns 200 and inserts Event row", %{conn: conn} do
      body = Jason.encode!(%{
        "action" => "opened",
        "sender" => %{"login" => "octocat"},
        "issue" => %{"number" => 1, "title" => "Bug report"}
      })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      event = Repo.one(from e in Schema.Event, where: e.event_type == "issues.opened")
      assert event != nil
      assert event.source == "github"
      assert event.actor_id == "octocat"
    end

    test "invalid HMAC returns 403 and no Event row", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened", "sender" => %{"login" => "octocat"}})
      bad_sig = compute_sig("wrong_secret", body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", bad_sig)
        |> put_req_header("x-github-event", "issues")
        |> post(~p"/api/webhooks/github", body)

      assert conn.status == 403
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end

    test "missing X-Hub-Signature-256 header returns 403", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened", "sender" => %{"login" => "octocat"}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "issues")
        |> post(~p"/api/webhooks/github", body)

      assert conn.status == 403
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end
  end

  describe "event type handling" do
    test "unknown event type returns 200 and no Event row", %{conn: conn} do
      body = Jason.encode!(%{"sender" => %{"login" => "octocat"}})

      conn = signed_conn(conn, body, "star")

      assert conn.status == 200
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end

    test "push event returns 200 and inserts Event row", %{conn: conn} do
      body = Jason.encode!(%{
        "ref" => "refs/heads/main",
        "sender" => %{"login" => "octocat"}
      })

      conn = signed_conn(conn, body, "push")

      assert conn.status == 200
      event = Repo.one(from e in Schema.Event, where: e.event_type == "push")
      assert event != nil
    end
  end

  describe "thread_id resolution" do
    test "Closes #N in body sets Event.thread_id to matching Thread.id", %{conn: conn} do
      {:ok, thread} =
        %Schema.Thread{}
        |> Schema.Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "42",
          state: "unnoticed"
        })
        |> Repo.insert()

      body = Jason.encode!(%{
        "action" => "opened",
        "body" => "Closes #42",
        "sender" => %{"login" => "octocat"},
        "issue" => %{"number" => 42}
      })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      event = Repo.one(from e in Schema.Event, where: e.event_type == "issues.opened")
      assert event != nil
      assert event.thread_id == thread.id
    end

    test "no Closes/Fixes reference in body sets Event.thread_id to nil", %{conn: conn} do
      body = Jason.encode!(%{
        "action" => "opened",
        "body" => "This is a PR with no issue reference",
        "sender" => %{"login" => "octocat"}
      })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      event = Repo.one(from e in Schema.Event, where: e.event_type == "issues.opened")
      assert event != nil
      assert event.thread_id == nil
    end

    test "Fixes #N in body also resolves thread_id", %{conn: conn} do
      {:ok, thread} =
        %Schema.Thread{}
        |> Schema.Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "7",
          state: "unnoticed"
        })
        |> Repo.insert()

      body = Jason.encode!(%{
        "action" => "opened",
        "body" => "Fixes #7 - resolves the bug",
        "sender" => %{"login" => "octocat"}
      })

      conn = signed_conn(conn, body, "pull_request")

      assert conn.status == 200

      event = Repo.one(from e in Schema.Event, where: e.event_type == "pull_request.opened")
      assert event != nil
      assert event.thread_id == thread.id
    end
  end
end
