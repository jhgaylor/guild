defmodule Guild.Adapters.FountainTest do
  use ExUnit.Case, async: true

  alias Guild.Adapters.Fountain

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:guild, :fountain_token, "test_token")

    on_exit(fn ->
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :fountain_token)
    end)

    {:ok, bypass: bypass}
  end

  describe "dispatch_conversation/4" do
    test "POST /api/conversations returns {:ok, %{id: id}} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{data: %{id: "abc"}}))
      end)

      assert {:ok, %{id: "abc"}} = Fountain.dispatch_conversation("agent-1", nil, "hello")
    end

    test "returns {:ok, %{id: id}} on 200 as well", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{id: "xyz"}}))
      end)

      assert {:ok, %{id: "xyz"}} = Fountain.dispatch_conversation("agent-1", nil, "hello")
    end

    test "returns {:error, :transient, _} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert {:error, :transient, {:http_error, 429}} =
               Fountain.dispatch_conversation("agent-1", nil, "hello")
    end

    test "returns {:error, :permanent, _} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, :permanent, {:http_error, 404}} =
               Fountain.dispatch_conversation("agent-1", nil, "hello")
    end

    test "returns {:error, :permanent, _} on 403", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        Plug.Conn.resp(conn, 403, "forbidden")
      end)

      assert {:error, :permanent, {:http_error, 403}} =
               Fountain.dispatch_conversation("agent-1", nil, "hello")
    end

    test "returns {:error, :transient, _} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        Plug.Conn.resp(conn, 500, "server error")
      end)

      assert {:error, :transient, {:http_error, 500}} =
               Fountain.dispatch_conversation("agent-1", nil, "hello")
    end
  end

  describe "send_prompt/2" do
    test "POST /api/conversations/:id/prompts returns {:ok, :sent} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/prompts", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      assert {:ok, :sent} = Fountain.send_prompt("conv-1", "continue please")
    end

    test "returns {:error, :transient, _} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/prompts", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert {:error, :transient, {:http_error, 429}} = Fountain.send_prompt("conv-1", "prompt")
    end

    test "returns {:error, :permanent, _} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/prompts", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, :permanent, {:http_error, 404}} = Fountain.send_prompt("conv-1", "prompt")
    end
  end

  describe "get_status/1" do
    test "GET /api/conversations/:id returns {:ok, :idle} for idle status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{id: "conv-1", status: "idle"}}))
      end)

      assert {:ok, :idle} = Fountain.get_status("conv-1")
    end

    test "returns {:ok, :running} for running status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "running"}}))
      end)

      assert {:ok, :running} = Fountain.get_status("conv-1")
    end

    test "returns {:ok, :pending} for pending status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "pending"}}))
      end)

      assert {:ok, :pending} = Fountain.get_status("conv-1")
    end

    test "returns {:ok, :terminated} for terminated status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "terminated"}}))
      end)

      assert {:ok, :terminated} = Fountain.get_status("conv-1")
    end

    test "returns {:error, :unexpected, _} for unknown status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "exploded"}}))
      end)

      assert {:error, :unexpected, _} = Fountain.get_status("conv-1")
    end

    test "returns {:error, :transient, _} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert {:error, :transient, {:http_error, 429}} = Fountain.get_status("conv-1")
    end

    test "returns {:error, :permanent, _} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, :permanent, {:http_error, 404}} = Fountain.get_status("conv-1")
    end
  end

  describe "terminate_conversation/1" do
    test "POST /api/conversations/:id/terminate returns {:ok, :terminated} on 200", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/terminate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      assert {:ok, :terminated} = Fountain.terminate_conversation("conv-1")
    end

    test "returns {:error, :transient, _} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/terminate", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert {:error, :transient, {:http_error, 429}} = Fountain.terminate_conversation("conv-1")
    end

    test "returns {:error, :permanent, _} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/conversations/conv-1/terminate", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, :permanent, {:http_error, 404}} = Fountain.terminate_conversation("conv-1")
    end
  end

  describe "observe_conversation/1" do
    test "GET stream endpoint returns {:ok, text}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1/stream", fn conn ->
        body = "data: hello\ndata:  world\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, text} = Fountain.observe_conversation("conv-1")
      assert is_binary(text)
    end

    test "returns {:error, :permanent, _} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-1/stream", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:error, :permanent, {:http_error, 404}} = Fountain.observe_conversation("conv-1")
    end

    test "returns {:error, :transient, _} on 503", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-123/stream", fn conn ->
        Plug.Conn.resp(conn, 503, "service unavailable")
      end)

      assert {:error, :transient, _} = Fountain.observe_conversation("conv-123")
    end
  end
end
