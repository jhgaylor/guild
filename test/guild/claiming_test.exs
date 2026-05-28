defmodule Guild.ClaimingTest do
  use Guild.DataCase, async: false

  import Ecto.Query
  alias Guild.Repo
  alias Guild.Claiming
  alias Guild.Schema.{Thread, Artifact}

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

  describe "claim_issue/2" do
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

    test "concurrent claims: exactly one succeeds and one gets :already_claimed", %{
      bypass: bypass
    } do
      # Only one Fountain dispatch should occur — the losing caller aborts before dispatch
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
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

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      err_count = Enum.count(results, &match?({:error, :already_claimed}, &1))

      assert ok_count == 1, "expected exactly one successful claim, got: #{inspect(results)}"
      assert err_count == 1, "expected exactly one :already_claimed, got: #{inspect(results)}"
    end
  end
end
