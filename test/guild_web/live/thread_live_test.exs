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

  test "GET /threads/:id renders events section", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "Events"
  end

  test "GET /threads/:id renders artifacts section", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "Artifacts"
  end

  test "GET /threads/:id renders context_notes section", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "Context Notes"
  end

  test "unauthenticated live mount is rejected", %{conn: conn, thread: thread} do
    # Without auth headers the :auth pipeline halts with 401.
    # The halted conn (no static token) causes LiveViewTest to raise.
    assert_raise FunctionClauseError, fn ->
      live(conn, ~p"/threads/#{thread.id}")
    end
  end

  test "GET /threads/:id shows stuck warning banner for over-threshold executing thread",
       %{conn: conn} do
    {:ok, stuck_thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "stuck-show-1",
        state: "executing"
      })
      |> Guild.Repo.insert()

    # Set updated_at to 3 hours ago (exceeds 2-hour executing threshold)
    past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
    import Ecto.Query
    Guild.Repo.update_all(
      from(t in Guild.Schema.Thread, where: t.id == ^stuck_thread.id),
      set: [updated_at: past]
    )

    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{stuck_thread.id}")
    assert html =~ "stuck"
    assert html =~ "Warning"
  end
end
