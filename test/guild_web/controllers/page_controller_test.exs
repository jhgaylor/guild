defmodule GuildWeb.PageControllerTest do
  use GuildWeb.ConnCase

  test "GET / returns 200 with Guild title and marketing copy", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Guild"
    assert body =~ "watches your repos"
    assert body =~ "bot-ready issues"
  end

  test "GET / contains link to /threads", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~p"/threads"
  end

  test "GET / contains link to /jobs", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~p"/jobs"
  end
end
