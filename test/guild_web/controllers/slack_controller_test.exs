defmodule GuildWeb.SlackControllerTest do
  use GuildWeb.ConnCase, async: false

  alias Guild.Repo
  alias Guild.Schema.Thread

  @test_secret "test_slack_signing_secret"

  setup do
    Application.put_env(:guild, :slack_signing_secret, @test_secret)
    on_exit(fn -> Application.delete_env(:guild, :slack_signing_secret) end)
    :ok
  end

  defp insert_thread(anchor_id, state \\ "executing") do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{anchor_type: "github_issue", anchor_id: to_string(anchor_id), state: state})
      |> Repo.insert()

    thread
  end

  defp slack_conn(conn, body_text, opts \\ []) do
    ts = to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @test_secret)

    base = "v0:#{ts}:#{body_text}"
    sig = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-slack-request-timestamp", ts)
    |> put_req_header("x-slack-signature", sig)
    |> post(~p"/slack/commands", body_text)
  end

  describe "signature verification" do
    test "valid signature returns 200", %{conn: conn} do
      insert_thread(101)
      body = "command=%2Fguild&text=hold+101"
      conn = slack_conn(conn, body)
      assert conn.status == 200
    end

    test "invalid signature returns 403", %{conn: conn} do
      body = "command=%2Fguild&text=hold+200"
      conn = slack_conn(conn, body, secret: "wrong_secret")
      assert conn.status == 403
    end

    test "missing SLACK_SIGNING_SECRET returns 403", %{conn: conn} do
      Application.delete_env(:guild, :slack_signing_secret)
      body = "command=%2Fguild&text=hold+300"
      ts = to_string(System.system_time(:second))

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-slack-request-timestamp", ts)
        |> put_req_header("x-slack-signature", "v0=fake")
        |> post(~p"/slack/commands", body)

      assert conn.status == 403
    end

    test "stale timestamp (older than 5 min) returns 403", %{conn: conn} do
      stale_ts = System.system_time(:second) - 310
      body = "command=%2Fguild&text=hold+400"
      conn = slack_conn(conn, body, ts: stale_ts)
      assert conn.status == 403
    end
  end

  describe "hold command" do
    test "sets thread.held = true and returns ephemeral ack", %{conn: conn} do
      thread = insert_thread(500)
      body = "command=%2Fguild&text=hold+500"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end
  end

  describe "resume command" do
    test "sets thread.held = false and returns ephemeral ack", %{conn: conn} do
      thread = insert_thread(600)
      # Set held first
      Repo.update!(Thread.changeset(thread, %{held: true}))

      body = "command=%2Fguild&text=resume+600"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == false
    end
  end

  describe "abandon command" do
    test "transitions thread to abandoned and clears owner", %{conn: conn} do
      thread = insert_thread(700, "executing")
      Repo.update!(Thread.changeset(thread, %{owner: "worker-abc"}))

      body = "command=%2Fguild&text=abandon+700"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "abandoned"
      assert is_nil(updated.owner)
    end
  end
end
