defmodule Guild.Workers.ClaimWorkerTest do
  use Guild.DataCase, async: false
  use Oban.Testing, repo: Guild.Repo

  import Ecto.Query
  alias Guild.Repo
  alias Guild.Workers.ClaimWorker
  alias Guild.Schema.{Thread, Artifact, Worker}

  @test_agent_id "test-agent-id"

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:guild, :fountain_api_key, "test_token")
    Application.put_env(:guild, :guild_implementer_agent_id, @test_agent_id)

    on_exit(fn ->
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :fountain_api_key)
      Application.delete_env(:guild, :guild_implementer_agent_id)
    end)

    {:ok, bypass: bypass}
  end

  describe "perform/1" do
    test "successful claim: thread ends in executing with fountain_conversation artifact", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-worker-123"}}))
      end)

      job_args = %{"repo" => "owner/repo", "issue_number" => 101}

      assert :ok = perform_job(ClaimWorker, job_args)

      thread =
        Repo.one!(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "101"
        )

      assert thread.state == "executing"

      artifact =
        Repo.get_by(Artifact,
          thread_id: thread.id,
          artifact_type: "fountain_conversation"
        )

      assert artifact != nil
      assert artifact.external_id == "conv-worker-123"
    end

    test "worker_id is threaded from job args to claim_issue", %{bypass: bypass} do
      Repo.insert!(%Worker{
        worker_id: "routed-worker",
        fountain_agent_id: @test_agent_id,
        vault_id: ""
      })

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-routed"}}))
      end)

      job_args = %{"repo" => "owner/repo", "issue_number" => 202, "worker_id" => "routed-worker"}

      assert :ok = perform_job(ClaimWorker, job_args)

      thread =
        Repo.one!(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "202"
        )

      assert thread.state == "executing"
      assert thread.owner == "routed-worker"
    end

    test "CAS: two jobs for same thread with different worker_ids — one wins, one cancels", %{
      bypass: bypass
    } do
      Repo.insert!(%Worker{
        worker_id: "cas-worker-1",
        fountain_agent_id: @test_agent_id,
        vault_id: ""
      })

      Repo.insert!(%Worker{
        worker_id: "cas-worker-2",
        fountain_agent_id: @test_agent_id,
        vault_id: ""
      })

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-cas-1"}}))
      end)

      # First worker claims successfully
      assert :ok =
               perform_job(ClaimWorker, %{
                 "repo" => "owner/repo",
                 "issue_number" => 777,
                 "worker_id" => "cas-worker-1"
               })

      # Second worker is blocked by CAS (thread.owner already set to "cas-worker-1")
      assert {:cancel, :already_claimed} =
               perform_job(ClaimWorker, %{
                 "repo" => "owner/repo",
                 "issue_number" => 777,
                 "worker_id" => "cas-worker-2"
               })
    end

    test "duplicate prevention: worker is configured with uniqueness constraints" do
      opts = ClaimWorker.__opts__()
      unique_opts = Keyword.get(opts, :unique)

      assert unique_opts != nil, "ClaimWorker must declare unique options"
      assert Keyword.get(unique_opts, :fields) == [:args],
             "Unique constraint should be scoped to job args"

      assert Keyword.get(unique_opts, :period) != nil,
             "Unique constraint must specify a deduplication period"
    end

    test "transient error: {:error, reason} triggers automatic retry" do
      Application.put_env(:guild, :fountain_base_url, "http://localhost:1")

      job_args = %{"repo" => "owner/repo", "issue_number" => 303}

      result = perform_job(ClaimWorker, job_args)

      assert match?({:error, _}, result),
             "Expected {:error, reason} for transient failure, got: #{inspect(result)}"
    end
  end
end
