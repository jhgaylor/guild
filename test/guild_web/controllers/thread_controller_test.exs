defmodule GuildWeb.ThreadControllerTest do
  use GuildWeb.ConnCase

  setup do
    {:ok, thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_pr",
        anchor_id: "test-anchor-123",
        state: "noticed"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /threads returns 200 and shows thread row", %{conn: conn, thread: thread} do
    conn = get(conn, ~p"/threads")
    response_body = html_response(conn, 200)
    assert response_body =~ "github_pr"
    assert response_body =~ thread.anchor_id
  end
end
