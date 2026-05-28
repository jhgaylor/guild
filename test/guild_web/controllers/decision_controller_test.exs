defmodule GuildWeb.DecisionControllerTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  setup do
    {:ok, thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_pr",
        anchor_id: "decision-test-anchor",
        state: "noticed"
      })
      |> Guild.Repo.insert()

    {:ok, _decision} =
      %Guild.Schema.DecisionsLog{}
      |> Guild.Schema.DecisionsLog.changeset(%{
        thread_id: thread.id,
        decision_type: "transition",
        reasoning: "Test reasoning for this decision"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /decisions returns 200", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/decisions")
    assert html_response(conn, 200) =~ "Decisions"
  end
end
