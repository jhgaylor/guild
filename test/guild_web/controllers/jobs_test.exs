defmodule GuildWeb.JobsTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  # Slice 1 owns the auth gate on /jobs (the Oban Web dashboard is mounted inside
  # the :auth pipeline). We assert the boundary here. The authenticated dashboard
  # render itself requires Oban.Met, which only runs when Oban is started normally
  # — not under `testing: :inline` — so the full 200 render is verified live in
  # prod rather than in this unit test.
  test "GET /jobs without credentials returns 401", %{conn: conn} do
    conn = get(conn, "/jobs")
    assert conn.status == 401
  end

  test "GET /jobs with credentials passes the auth gate (does not 401)", %{conn: conn} do
    # Past auth, the Oban Web LiveView attempts to mount and raises because
    # Oban.Met is not started under :inline testing. Reaching that raise proves
    # the request cleared BasicAuth (an unauthenticated request 401s before mount).
    assert_raise RuntimeError, ~r/Oban\.Met/, fn ->
      conn |> with_auth() |> get("/jobs")
    end
  end
end
