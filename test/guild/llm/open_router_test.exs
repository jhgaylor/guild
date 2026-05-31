defmodule Guild.LLM.OpenRouterTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :openrouter_api_key, "test-key")
    Application.put_env(:guild, :openrouter_api_url, "http://localhost:#{bypass.port}/v1/chat/completions")
    on_exit(fn ->
      Application.delete_env(:guild, :openrouter_api_key)
      Application.delete_env(:guild, :openrouter_api_url)
    end)
    {:ok, bypass: bypass}
  end

  test "returns {:ok, text} on success", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"hello"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, "hello"} = Guild.LLM.OpenRouter.complete("test prompt")
  end

  test "returns {:error, :no_api_key} when key absent" do
    Application.delete_env(:guild, :openrouter_api_key)
    assert {:error, :no_api_key} = Guild.LLM.OpenRouter.complete("test")
  end

  test "returns {:error, :unauthorized} on 401", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
    end)
    assert {:error, :unauthorized} = Guild.LLM.OpenRouter.complete("test")
  end

  test "returns {:error, {:server_error, 500}} on 500", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 500, "oops")
    end)
    assert {:error, {:server_error, 500}} = Guild.LLM.OpenRouter.complete("test")
  end
end
