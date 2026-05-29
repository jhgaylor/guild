defmodule GuildWeb.JobsTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  test "GET /jobs without credentials returns 401", %{conn: conn} do
    conn = get(conn, "/jobs")
    assert conn.status == 401
  end

  test "GET /jobs with credentials returns 200", %{conn: conn} do
    conn = conn |> with_auth() |> get("/jobs")
    assert conn.status == 200
  end
end
