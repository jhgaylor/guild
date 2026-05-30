defmodule GuildWeb.LinearControllerTest do
  use GuildWeb.ConnCase, async: false

  import Ecto.Query
  alias Guild.{Repo, Schema}

  @test_secret "test_linear_webhook_secret"

  setup do
    Application.put_env(:guild, :linear_webhook_secret, @test_secret)
    on_exit(fn -> Application.delete_env(:guild, :linear_webhook_secret) end)
    :ok
  end

  defp compute_sig(secret, body) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp signed_conn(conn, body, opts \\ []) do
    secret = Keyword.get(opts, :secret, @test_secret)
    sig = compute_sig(secret, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("linear-signature", sig)
    |> post(~p"/linear/webhooks", body)
  end

  describe "signature verification" do
    test "valid signature + issue payload inserts linear.issue_updated Event", %{conn: conn} do
      body =
        Jason.encode!(%{
          "type" => "Issue",
          "action" => "update",
          "webhookId" => "wh-001",
          "data" => %{
            "id" => "issue-uuid-1",
            "title" => "Fix the bug",
            "description" => "This is broken"
          }
        })

      conn = signed_conn(conn, body)

      assert conn.status == 200

      event = Repo.one(from e in Schema.Event, where: e.event_type == "linear.Issue")
      assert event != nil
      assert event.source == "linear"
      assert event.idempotency_key == "linear:Issue:wh-001"
    end

    test "invalid signature returns 403 and no Event row", %{conn: conn} do
      body = Jason.encode!(%{"type" => "Issue", "webhookId" => "wh-002"})

      conn = signed_conn(conn, body, secret: "wrong_secret")

      assert conn.status == 403
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end

    test "missing LINEAR_WEBHOOK_SECRET returns 403", %{conn: conn} do
      Application.delete_env(:guild, :linear_webhook_secret)

      body = Jason.encode!(%{"type" => "Issue", "webhookId" => "wh-003"})
      sig = compute_sig(@test_secret, body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", sig)
        |> post(~p"/linear/webhooks", body)

      assert conn.status == 403
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end

    test "missing Linear-Signature header returns 403", %{conn: conn} do
      body = Jason.encode!(%{"type" => "Issue", "webhookId" => "wh-004"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/linear/webhooks", body)

      assert conn.status == 403
      assert Repo.aggregate(Schema.Event, :count, :id) == 0
    end
  end

  describe "event type mapping" do
    test "type field is prefixed with 'linear.' in event_type", %{conn: conn} do
      body =
        Jason.encode!(%{
          "type" => "Comment",
          "action" => "create",
          "webhookId" => "wh-005",
          "data" => %{"id" => "comment-uuid-1", "body" => "Looks good"}
        })

      conn = signed_conn(conn, body)

      assert conn.status == 200
      event = Repo.one(from e in Schema.Event, where: e.event_type == "linear.Comment")
      assert event != nil
    end

    test "thread_id is nil when no GitHub issue reference in payload", %{conn: conn} do
      body =
        Jason.encode!(%{
          "type" => "Issue",
          "webhookId" => "wh-006",
          "data" => %{"id" => "issue-2", "title" => "No github ref here"}
        })

      conn = signed_conn(conn, body)

      assert conn.status == 200
      event = Repo.one(from e in Schema.Event, where: e.idempotency_key == "linear:Issue:wh-006")
      assert event != nil
      assert is_nil(event.thread_id)
    end
  end
end
