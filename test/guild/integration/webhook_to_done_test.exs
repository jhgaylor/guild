defmodule Guild.Integration.WebhookToDoneTest do
  use GuildWeb.ConnCase, async: false

  @moduletag :integration

  import Ecto.Query
  alias Guild.{Repo, Schema}

  @test_secret "test"

  setup do
    # Make claiming synchronous for the test
    Application.put_env(:guild, :claim_async, false)

    # Stub Fountain via Bypass
    bypass = Bypass.open()
    Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:guild, :fountain_api_key, "test_token")
    Application.put_env(:guild, :guild_implementer_agent_id, "test-agent")
    Application.put_env(:guild, :github_webhook_secret, @test_secret)

    # GitHub TestAdapter: configure list_pull_requests to return a matching PR
    Guild.GitHub.TestAdapter.configure(:list_pull_requests, {
      :ok,
      [
        %{
          "number" => 1,
          "html_url" => "https://github.com/jhgaylor/guild/pull/1",
          "body" => "Closes #3"
        }
      ]
    })

    on_exit(fn ->
      Application.put_env(:guild, :claim_async, true)
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :fountain_api_key)
      Application.delete_env(:guild, :guild_implementer_agent_id)
      Application.delete_env(:guild, :github_webhook_secret)
    end)

    {:ok, bypass: bypass}
  end

  defp sign_payload(body) do
    secret = Application.get_env(:guild, :github_webhook_secret, "test")
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp issues_opened_payload(issue_number, labels) do
    Jason.encode!(%{
      "action" => "opened",
      "issue" => %{
        "number" => issue_number,
        "body" => "Test issue body",
        "labels" => Enum.map(labels, fn l -> %{"name" => l} end)
      },
      "repository" => %{"full_name" => "jhgaylor/guild"},
      "sender" => %{"login" => "testuser"}
    })
  end

  defp pr_merged_payload(pr_number) do
    Jason.encode!(%{
      "action" => "closed",
      "pull_request" => %{
        "number" => pr_number,
        "merged" => true,
        "body" => "Closes #3"
      },
      "repository" => %{"full_name" => "jhgaylor/guild"},
      "sender" => %{"login" => "testuser"}
    })
  end

  test "full cycle: webhook bot-ready → claiming → pr_open → done", %{conn: conn, bypass: bypass} do
    # Stub Fountain: POST /api/conversations → conv-id
    Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "fake-conv-id"}}))
    end)

    # Stub Fountain: GET /api/conversations/:id → idle
    Bypass.expect(bypass, "GET", "/api/conversations/fake-conv-id", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: %{id: "fake-conv-id", status: "idle"}}))
    end)

    # Step 1: POST issues.opened webhook with bot-ready label
    body = issues_opened_payload(3, ["bot-ready"])
    sig = sign_payload(body)

    conn1 =
      conn
      |> put_req_header("x-github-event", "issues")
      |> put_req_header("x-hub-signature-256", sig)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-delivery", Ecto.UUID.generate())
      |> post("/api/webhooks/github", body)

    assert conn1.status == 200

    # Step 2: Assert Event row inserted
    assert Repo.one(from e in Schema.Event, where: e.event_type == "issues.opened") != nil

    # Step 3: Assert Thread in :executing with fountain_conversation artifact
    thread =
      Repo.get_by!(Schema.Thread, anchor_type: "github_issue", anchor_id: "3")

    assert thread.state == "executing"

    assert Repo.get_by(Schema.Artifact,
             thread_id: thread.id,
             artifact_type: "fountain_conversation"
           ) != nil

    # Step 4: Reconcile Pass A — executing → pr_open (Fountain returns :idle, PR found)
    Guild.Reconcile.reconcile_all()
    thread = Repo.get!(Schema.Thread, thread.id)
    assert thread.state == "pr_open"

    assert Repo.get_by(Schema.Artifact, thread_id: thread.id, artifact_type: "pull_request") !=
             nil

    # Step 5: POST pull_request.closed + merged webhook
    body2 = pr_merged_payload(1)
    sig2 = sign_payload(body2)

    conn2 =
      build_conn()
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", sig2)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-delivery", Ecto.UUID.generate())
      |> post("/api/webhooks/github", body2)

    assert conn2.status == 200

    # Step 6: Assert pull_request.merged event inserted with thread_id resolved
    merged_event =
      Repo.one(from e in Schema.Event, where: e.event_type == "pull_request.merged")

    assert merged_event != nil
    assert merged_event.thread_id == thread.id

    # Step 7: Reconcile Pass B — pr_open → done (merged event present)
    Guild.Reconcile.reconcile_all()
    thread = Repo.get!(Schema.Thread, thread.id)
    assert thread.state == "done"
  end
end
