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

  test "returns {:ok, map with text + nil usage} when response has no usage", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"hello"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, resp} = Guild.LLM.OpenRouter.complete("test prompt")
    assert resp.text == "hello"
    assert resp.prompt_tokens == nil
    assert resp.completion_tokens == nil
    assert resp.cost_usd == nil
    # When the response omits "model" we fall back to the requested model id.
    assert is_binary(resp.model)
  end

  test "parses usage + cost + model from response", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = Jason.encode!(%{
        model: "google/gemini-2.5-flash",
        choices: [%{message: %{content: "hi"}}],
        usage: %{prompt_tokens: 88, completion_tokens: 12, total_tokens: 100, cost: 0.0000234}
      })
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, resp} = Guild.LLM.OpenRouter.complete("test prompt")
    assert resp.text == "hi"
    assert resp.model == "google/gemini-2.5-flash"
    assert resp.prompt_tokens == 88
    assert resp.completion_tokens == 12
    assert resp.cost_usd == 0.0000234
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
