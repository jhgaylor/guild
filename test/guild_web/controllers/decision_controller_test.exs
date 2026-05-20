defmodule GuildWeb.DecisionControllerTest do
  use GuildWeb.ConnCase

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
    conn = get(conn, ~p"/decisions")
    assert html_response(conn, 200) =~ "Decisions"
  end
end
