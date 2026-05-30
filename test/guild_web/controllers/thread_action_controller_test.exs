defmodule GuildWeb.ThreadActionControllerTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp insert_worker! do
    Guild.Repo.insert!(%Guild.Schema.Worker{
      worker_id: "test-worker",
      fountain_agent_id: "agent-uuid",
      vault_id: "vault-uuid"
    })
  end

  defp insert_thread!(attrs \\ %{}) do
    defaults = %Guild.Schema.Thread{
      anchor_type: "github_issue",
      anchor_id: "999",
      state: "executing",
      held: false
    }
    Guild.Repo.insert!(Map.merge(defaults, attrs))
  end

  setup do
    insert_worker!()
    on_exit(fn ->
      Guild.Repo.delete_all(Guild.Schema.Thread)
      Guild.Repo.delete_all(Guild.Schema.Worker)
    end)
    :ok
  end

  describe "POST /threads/:id/hold" do
    test "without auth returns 401", %{conn: conn} do
      thread = insert_thread!()
      conn = post(conn, ~p"/threads/#{thread.id}/hold")
      assert conn.status == 401
    end

    test "with auth on executing thread sets held=true and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: false})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/hold")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.held == true
    end
  end

  describe "POST /threads/:id/resume" do
    test "with auth on held thread sets held=false and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: true})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/resume")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.held == false
    end
  end

  describe "POST /threads/:id/abandon" do
    test "with auth on non-terminal thread transitions to abandoned and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: false})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/abandon")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.state == "abandoned"
    end
  end
end
