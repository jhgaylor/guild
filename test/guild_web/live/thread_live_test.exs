defmodule GuildWeb.ThreadLiveTest do
  use GuildWeb.ConnCase
  import Phoenix.LiveViewTest

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
        anchor_id: "live-test-anchor-456",
        state: "executing"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /threads/:id renders thread detail", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ thread.id
    assert html =~ "github_pr"
    assert html =~ "live-test-anchor-456"
    assert html =~ "executing"
  end

  test "unauthenticated live mount is rejected", %{conn: conn, thread: thread} do
    # Without auth headers the :auth pipeline halts with 401.
    # The halted conn (no static token) causes LiveViewTest to raise.
    assert_raise FunctionClauseError, fn ->
      live(conn, ~p"/threads/#{thread.id}")
    end
  end
end
