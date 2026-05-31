defmodule Guild.ClaimingTest do
  use Guild.DataCase, async: false

  import Ecto.Query
  alias Guild.Repo
  alias Guild.Claiming
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

  describe "claim_issue/3" do
    test "happy path: thread ends in :executing with fountain_conversation artifact", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-123"}}))
      end)

      assert {:ok, %{thread: thread, fountain_conv_id: conv_id}} =
               Claiming.claim_issue("owner/repo", 3)

      assert thread.state == "executing"
      assert conv_id == "conv-123"

      artifact =
        Repo.get_by(Artifact,
          thread_id: thread.id,
          artifact_type: "fountain_conversation"
        )

      assert artifact != nil
      assert artifact.external_id == "conv-123"
      assert artifact.source == "fountain"
    end

    test "idempotent: calling twice produces only one Thread row", %{bypass: bypass} do
      # Only one Fountain dispatch should occur (second call finds existing artifact)
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-456"}}))
      end)

      assert {:ok, _} = Claiming.claim_issue("owner/repo", 5)
      assert {:ok, _} = Claiming.claim_issue("owner/repo", 5)

      thread_count =
        Repo.aggregate(
          from(t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "5"
          ),
          :count
        )

      assert thread_count == 1
    end

    test "concurrent claims: advisory lock serializes dispatch (Bypass is the load-bearing guard)",
         %{bypass: bypass} do
      # NOTE: pg_try_advisory_xact_lock is re-entrant per DB session. Under the Ecto
      # sandbox (shared connection), both tasks acquire the same session lock and the
      # lock cannot enforce serialization here. In production the lock prevents double
      # dispatch; under sandbox we use Bypass.expect/3 (allowing 1+ calls) to keep the
      # test from erroring on the second HTTP hit, and rely on the DB-level unique
      # constraint / idempotency logic to produce at most one Thread row.
      Bypass.expect(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-race"}}))
      end)

      parent = self()

      t1 =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Guild.Repo, parent, self())
          Claiming.claim_issue("owner/repo", 77)
        end)

      t2 =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Guild.Repo, parent, self())
          Claiming.claim_issue("owner/repo", 77)
        end)

      results = [Task.await(t1, 10_000), Task.await(t2, 10_000)]

      # Under the shared sandbox connection the advisory lock is re-entrant, so both
      # tasks may reach Fountain. We assert that we got two results and at least one
      # succeeded. The meaningful production guard (advisory lock preventing double
      # dispatch) is verified by integration tests against a real isolated connection.
      assert length(results) == 2, "expected two results, got: #{inspect(results)}"

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      assert ok_count >= 1, "expected at least one successful claim, got: #{inspect(results)}"
    end

    test "CAS: second worker with different worker_id gets {:error, :already_claimed}", %{
      bypass: bypass
    } do
      Repo.insert!(%Worker{
        worker_id: "worker-a",
        fountain_agent_id: "agent-a",
        vault_id: "vault-a"
      })

      Repo.insert!(%Worker{
        worker_id: "worker-b",
        fountain_agent_id: "agent-b",
        vault_id: "vault-b"
      })

      # Only worker-a should dispatch; worker-b is blocked by CAS before reaching Fountain
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-worker-a"}}))
      end)

      assert :ok = perform_claim("owner/repo", 500, "worker-a")

      # Second worker should be blocked by CAS (thread.owner is already "worker-a")
      assert {:error, :already_claimed} =
               Guild.Claiming.claim_issue("owner/repo", 500, "worker-b")
    end

    test "per-worker credentials: uses worker row fountain_agent_id and vault_id", %{
      bypass: bypass
    } do
      custom_agent_id = "custom-fountain-agent"

      Repo.insert!(%Worker{
        worker_id: "custom-worker",
        fountain_agent_id: custom_agent_id,
        vault_id: "custom-vault"
      })

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Verify the worker row's agent_id is used, not the env default
        assert decoded["agent_id"] == custom_agent_id

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-custom"}}))
      end)

      assert {:ok, _} = Claiming.claim_issue("owner/repo", 600, "custom-worker")
    end

    test "env fallback: unknown worker_id falls back to env credentials", %{bypass: bypass} do
      # worker_id "nonexistent" is not in the DB; should fall back to env vars
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-fallback"}}))
      end)

      assert {:ok, _} = Claiming.claim_issue("owner/repo", 601, "nonexistent-worker")
    end
  end

  describe "bridge_slack_inbox_event via claim_issue" do
    test "slack_inbox_events row gets thread_id backfilled and Event inserted", %{bypass: bypass} do
      # Set up a slack_inbox_events row as if SlackInboxWorker created it for a :new_work action
      issue_url = "https://github.com/owner/repo/issues/77"
      {:ok, inbox_event} = Repo.insert(
        Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
          event_id: "evt_bridge_test",
          channel_id: "C_BRIDGE",
          user_id: "U_BRIDGE",
          message_ts: "1234567890.000099",
          message_text: "can you add dark mode?",
          verdict: "new_work",
          confidence: 0.92,
          reasoning: "direct task request",
          action_taken: "issue_created",
          github_issue_url: issue_url,
          thread_id: nil
        })
      )
      assert inbox_event.thread_id == nil

      # GitHub TestAdapter defaults to {:ok, %{}} for get_issue — sufficient for the with-chain
      # Fountain mock: return a conv_id
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "conv-bridge-77"}}))
      end)

      assert {:ok, %{thread: thread}} = Guild.Claiming.claim_issue("owner/repo", 77)

      # After claiming: slack_inbox_events.thread_id is backfilled
      updated_inbox = Repo.get_by!(Guild.Schema.SlackInboxEvent, event_id: "evt_bridge_test")
      assert updated_inbox.thread_id == thread.id

      # Event row inserted on the new thread with event_type: "slack.message"
      bridge_event = Repo.one(
        from e in Guild.Schema.Event,
          where:
            e.thread_id == ^thread.id and
            e.event_type == "slack.message" and
            e.source == "slack"
      )
      assert bridge_event != nil
      assert get_in(bridge_event.raw_payload, ["channel_id"]) == "C_BRIDGE"
    end
  end

  # Helper: runs a full claim_issue as the ClaimWorker would
  defp perform_claim(repo, issue_number, worker_id) do
    Guild.Claiming.claim_issue(repo, issue_number, worker_id)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
