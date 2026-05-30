defmodule GuildWeb.WebhookControllerTest do
  use GuildWeb.ConnCase, async: false

  import Ecto.Query
  alias Guild.{Repo, Schema}
  alias Guild.Schema.Thread

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

  describe "bot-ready claiming" do
    setup do
      Application.put_env(:guild, :claim_async, false)
      bypass = Bypass.open()
      Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
      Application.put_env(:guild, :fountain_api_key, "test_token")
      Application.put_env(:guild, :guild_implementer_agent_id, "test-agent")

      # Seed the worker and repo rows required for multi-repo routing
      Repo.insert!(%Schema.Worker{
        worker_id: "default",
        fountain_agent_id: "test-agent",
        vault_id: ""
      })

      Repo.insert!(%Schema.Repo{
        full_name: "owner/repo",
        enabled: true,
        worker_id: "default"
      })

      on_exit(fn ->
        Application.delete_env(:guild, :claim_async)
        Application.delete_env(:guild, :fountain_base_url)
        Application.delete_env(:guild, :fountain_api_key)
        Application.delete_env(:guild, :guild_implementer_agent_id)
      end)

      {:ok, bypass: bypass}
    end

    test "issues.labeled with bot-ready label claims the issue", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-webhook"}}))
      end)

      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bot-ready"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 10, "labels" => [%{"name" => "bot-ready"}]},
          "repository" => %{"full_name" => "owner/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "10"
        )

      assert thread != nil
      assert thread.state == "executing"
    end

    test "issues.labeled with bot-ready enqueues job with correct worker_id", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-wid"}}))
      end)

      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bot-ready"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 20, "labels" => [%{"name" => "bot-ready"}]},
          "repository" => %{"full_name" => "owner/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      # Verify thread owner was set from the repo row's worker_id
      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "20"
        )

      assert thread != nil
      assert thread.owner == "default"
    end

    test "issues.labeled with non-bot-ready label does not create Thread", %{conn: conn} do
      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bug"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 11, "labels" => [%{"name" => "bug"}]},
          "repository" => %{"full_name" => "owner/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "11"
        )

      assert thread == nil
    end
  end

  describe "multi-repo routing" do
    setup do
      Application.put_env(:guild, :claim_async, false)
      bypass = Bypass.open()
      Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
      Application.put_env(:guild, :fountain_api_key, "test_token")
      Application.put_env(:guild, :guild_implementer_agent_id, "test-agent")

      on_exit(fn ->
        Application.delete_env(:guild, :claim_async)
        Application.delete_env(:guild, :fountain_base_url)
        Application.delete_env(:guild, :fountain_api_key)
        Application.delete_env(:guild, :guild_implementer_agent_id)
      end)

      {:ok, bypass: bypass}
    end

    test "webhook for unconfigured repo returns 200 with no job enqueued", %{conn: conn} do
      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bot-ready"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 30, "labels" => [%{"name" => "bot-ready"}]},
          "repository" => %{"full_name" => "unconfigured/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      # Must still return 200 (not 4xx)
      assert conn.status == 200

      # No thread should be created (no job was enqueued/run)
      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "30"
        )

      assert thread == nil
    end

    test "webhook for disabled repo returns 200 with no job enqueued", %{conn: conn} do
      Repo.insert!(%Schema.Worker{
        worker_id: "disabled-worker",
        fountain_agent_id: "test-agent",
        vault_id: ""
      })

      Repo.insert!(%Schema.Repo{
        full_name: "disabled/repo",
        enabled: false,
        worker_id: "disabled-worker"
      })

      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bot-ready"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 31, "labels" => [%{"name" => "bot-ready"}]},
          "repository" => %{"full_name" => "disabled/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "31"
        )

      assert thread == nil
    end

    test "webhook for configured repo routes to correct worker_id", %{conn: conn, bypass: bypass} do
      Repo.insert!(%Schema.Worker{
        worker_id: "specific-worker",
        fountain_agent_id: "test-agent",
        vault_id: ""
      })

      Repo.insert!(%Schema.Repo{
        full_name: "configured/repo",
        enabled: true,
        worker_id: "specific-worker"
      })

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-specific"}}))
      end)

      body =
        Jason.encode!(%{
          "action" => "labeled",
          "label" => %{"name" => "bot-ready"},
          "sender" => %{"login" => "octocat"},
          "issue" => %{"number" => 40, "labels" => [%{"name" => "bot-ready"}]},
          "repository" => %{"full_name" => "configured/repo"}
        })

      conn = signed_conn(conn, body, "issues")

      assert conn.status == 200

      thread =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "40"
        )

      assert thread != nil
      assert thread.owner == "specific-worker"
    end

    test "two-repo routing: issues.opened dispatches correct worker_id per repo", %{
      conn: conn,
      bypass: bypass
    } do
      # Seed both a "default" and an "alt" worker row
      Repo.insert!(%Schema.Worker{
        worker_id: "default",
        fountain_agent_id: "test-agent",
        vault_id: ""
      })

      Repo.insert!(%Schema.Worker{
        worker_id: "alt",
        fountain_agent_id: "test-agent",
        vault_id: ""
      })

      # Seed repo-a → default worker, repo-b → alt worker
      Repo.insert!(%Schema.Repo{full_name: "owner/repo-a", enabled: true, worker_id: "default"})
      Repo.insert!(%Schema.Repo{full_name: "owner/repo-b", enabled: true, worker_id: "alt"})

      # Expect two Fountain API calls (one per repo, Oban inline mode runs jobs immediately)
      Bypass.expect(bypass, "POST", "/api/conversations", fn conn ->
        conv_id = "conv-routing-#{System.unique_integer([:positive])}"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: conv_id}}))
      end)

      body_a =
        Jason.encode!(%{
          "action" => "opened",
          "sender" => %{"login" => "octocat"},
          "issue" => %{
            "number" => 50,
            "title" => "Issue on repo-a",
            "labels" => [%{"name" => "bot-ready"}]
          },
          "repository" => %{"full_name" => "owner/repo-a"}
        })

      conn_a = signed_conn(conn, body_a, "issues")
      assert conn_a.status == 200

      # ClaimWorker runs inline and sets thread.owner from the Repo row's worker_id
      thread_a =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "50"
        )

      assert thread_a != nil
      assert thread_a.owner == "default"

      body_b =
        Jason.encode!(%{
          "action" => "opened",
          "sender" => %{"login" => "octocat"},
          "issue" => %{
            "number" => 51,
            "title" => "Issue on repo-b",
            "labels" => [%{"name" => "bot-ready"}]
          },
          "repository" => %{"full_name" => "owner/repo-b"}
        })

      conn_b = signed_conn(conn, body_b, "issues")
      assert conn_b.status == 200

      thread_b =
        Repo.one(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "51"
        )

      assert thread_b != nil
      assert thread_b.owner == "alt"
    end
  end
end
