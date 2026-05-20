defmodule GuildWeb.PageControllerTest do
  use GuildWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Guild"
    assert html_response(conn, 200) =~ "Threads"
    assert html_response(conn, 200) =~ "Decisions"
  end
end
