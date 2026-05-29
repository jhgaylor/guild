defmodule GuildWeb.ThreadControllerTest do
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
        anchor_id: "test-anchor-123",
        state: "noticed"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /threads without credentials returns 401", %{conn: conn} do
    conn = get(conn, ~p"/threads")
    assert conn.status == 401
  end

  test "GET /threads returns 200 and shows thread row", %{conn: conn, thread: thread} do
    conn = conn |> with_auth() |> get(~p"/threads")
    response_body = html_response(conn, 200)
    assert response_body =~ "github_pr"
    assert response_body =~ thread.anchor_id
  end

  test "GET /threads shows stuck badge for over-threshold executing thread", %{conn: conn} do
    {:ok, stuck_thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "stuck-index-1",
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

    conn = conn |> with_auth() |> get(~p"/threads")
    assert html_response(conn, 200) =~ "stuck"
  end
end
