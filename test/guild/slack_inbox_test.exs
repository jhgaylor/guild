defmodule Guild.SlackInboxTest do
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

  defp input(overrides \\ %{}) do
    Map.merge(%{
      message: "can you fix the login bug?",
      channel_id: "C123",
      channel_name: "guild",
      user_display_name: "Alice",
      default_repo: "owner/repo",
      open_threads: []
    }, overrides)
  end

  test "returns :new_work on valid classifier response", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      inner = Jason.encode!(%{verdict: "new_work", confidence: 0.95, reasoning: "direct task request", matched_thread_id: nil})
      body = Jason.encode!(%{choices: [%{message: %{content: inner}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "new_work", confidence: 0.95, thread_id: nil}} = Guild.SlackInbox.classify(input())
  end

  test "returns :noise with 0.0 confidence on malformed JSON", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = Jason.encode!(%{choices: [%{message: %{content: "not json at all"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.0}} = Guild.SlackInbox.classify(input())
  end

  test "returns :noise with 0.0 confidence on wrong JSON shape", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      inner = Jason.encode!(%{foo: "bar"})
      body = Jason.encode!(%{choices: [%{message: %{content: inner}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.0}} = Guild.SlackInbox.classify(input())
  end

  test "tolerates ```json markdown code fences (Gemini Flash behavior)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      fenced = "```json\n{\"verdict\":\"noise\",\"confidence\":0.9,\"reasoning\":\"casual chat\",\"matched_thread_id\":null}\n```"
      body = Jason.encode!(%{choices: [%{message: %{content: fenced}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.9}} = Guild.SlackInbox.classify(input())
  end

  test "tolerates plain ``` fences without 'json' tag", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      fenced = "```\n{\"verdict\":\"new_work\",\"confidence\":0.85,\"reasoning\":\"r\",\"matched_thread_id\":null}\n```"
      body = Jason.encode!(%{choices: [%{message: %{content: fenced}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "new_work", confidence: 0.85}} = Guild.SlackInbox.classify(input())
  end

  test "tolerates leading prose before the JSON object", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      prosed = "Sure! Here's the classification:\n{\"verdict\":\"noise\",\"confidence\":0.7,\"reasoning\":\"x\",\"matched_thread_id\":null}"
      body = Jason.encode!(%{choices: [%{message: %{content: prosed}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.7}} = Guild.SlackInbox.classify(input())
  end
end
