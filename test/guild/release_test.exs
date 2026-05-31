defmodule Guild.ReleaseTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()

    Application.put_env(:guild, :slack_bot_token, "xoxb-test")
    Application.put_env(:guild, :slack_channel_id, "C_TEST")
    Application.put_env(
      :guild,
      :slack_api_url,
      "http://localhost:#{bypass.port}/api/chat.postMessage"
    )

    on_exit(fn ->
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)
      Application.delete_env(:guild, :slack_api_url)
    end)

    {:ok, bypass: bypass}
  end

  describe "slack_ping/0" do
    test "returns :ok when Slack responds with ok: true", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ok":true,"channel":"C_TEST","ts":"111.222"}))
      end)

      assert Guild.Release.slack_ping() == :ok
    end

    test "returns :error when Slack responds with ok: false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ok":false,"error":"not_in_channel"}))
      end)

      assert Guild.Release.slack_ping() == :error
    end

    test "returns :error when Slack is not configured" do
      Application.delete_env(:guild, :slack_bot_token)

      assert Guild.Release.slack_ping() == :error
    end
  end
end
