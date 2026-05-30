defmodule Guild.Adapters.SlackTest do
  use ExUnit.Case, async: true

  alias Guild.Adapters.Slack

  describe "post_message/2 — not configured" do
    test "returns {:ok, :not_configured} when SLACK_BOT_TOKEN is absent" do
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)

      assert {:ok, :not_configured} = Slack.post_message("C123", "hello")
    end

    test "returns {:ok, :not_configured} when SLACK_CHANNEL_ID is absent" do
      Application.put_env(:guild, :slack_bot_token, "xoxb-test-token")
      Application.delete_env(:guild, :slack_channel_id)

      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
      end)

      assert {:ok, :not_configured} = Slack.post_message("C123", "hello")
    end

    test "returns {:ok, :not_configured} when both are absent" do
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)

      assert {:ok, :not_configured} = Slack.post_message("hello")
    end
  end

  describe "post_message/2 — with Bypass" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:guild, :slack_bot_token, "xoxb-test-token")
      Application.put_env(:guild, :slack_channel_id, "C_DEFAULT")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/api/chat.postMessage")

      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)

      {:ok, bypass: bypass}
    end

    test "POSTs to chat.postMessage with channel and text fields", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C123"
        assert decoded["text"] == "Hello World"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C123", ts: "12345.6789"}))
      end)

      assert {:ok, %{channel: "C123", ts: "12345.6789"}} = Slack.post_message("C123", "Hello World")
    end

    test "uses bearer token in Authorization header", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer xoxb-test-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      assert {:ok, _} = Slack.post_message("C123", "test")
    end

    test "uses default channel when none passed", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C_DEFAULT"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      assert {:ok, _} = Slack.post_message("hello from default channel")
    end

    test "returns {:error, :permanent, {:slack_error, _}} on Slack API ok=false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: false, error: "channel_not_found"}))
      end)

      assert {:error, :permanent, {:slack_error, "channel_not_found"}} =
               Slack.post_message("C123", "test")
    end

    test "returns {:error, :transient, _} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        Plug.Conn.resp(conn, 500, "server error")
      end)

      assert {:error, :transient, {:http_error, 500}} = Slack.post_message("C123", "test")
    end

    test "returns {:error, :permanent, _} on 403", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        Plug.Conn.resp(conn, 403, "forbidden")
      end)

      assert {:error, :permanent, {:http_error, 403}} = Slack.post_message("C123", "test")
    end

    test "includes blocks in payload when opts[:blocks] is given", %{bypass: bypass} do
      blocks = [
        %{type: "section", text: %{type: "mrkdwn", text: "Hello"}},
        %{
          type: "actions",
          elements: [
            %{type: "button", text: %{type: "plain_text", text: "Hold"}, action_id: "guild_hold", value: "42"}
          ]
        }
      ]

      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C123"
        assert decoded["text"] == "some text"
        assert is_list(decoded["blocks"])
        assert length(decoded["blocks"]) == 2

        action_ids =
          decoded["blocks"]
          |> Enum.filter(&(&1["type"] == "actions"))
          |> Enum.flat_map(& &1["elements"])
          |> Enum.map(& &1["action_id"])

        assert "guild_hold" in action_ids

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C123", ts: "12345.6789"}))
      end)

      assert {:ok, %{channel: "C123", ts: "12345.6789"}} = Slack.post_message("C123", "some text", blocks: blocks)
    end

    test "omits blocks key when opts is empty", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "blocks")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      assert {:ok, _} = Slack.post_message("C123", "no blocks here")
    end
  end
end
