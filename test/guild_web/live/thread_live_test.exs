defmodule GuildWeb.ThreadLiveTest do
  use GuildWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    {:ok, thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_pr",
        anchor_id: "live-test-anchor-456",
        state: "executing"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /threads/:id renders thread detail", %{conn: conn, thread: thread} do
    {:ok, _view, html} = live(conn, ~p"/threads/#{thread.id}")
    assert html =~ thread.id
    assert html =~ "github_pr"
    assert html =~ "live-test-anchor-456"
    assert html =~ "executing"
  end
end
