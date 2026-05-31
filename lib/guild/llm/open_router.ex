defmodule Guild.LLM.OpenRouter do
  @moduledoc """
  Stateless HTTP client for OpenRouter's chat completions API.
  Used for one-shot LLM classification tasks (ADR 0017).
  """

  require Logger

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o-mini"
  @timeout_ms 10_000

  @doc """
  Send a single-turn prompt and return the model's response plus usage metadata.

  Returns `{:ok, %{text:, model:, prompt_tokens:, completion_tokens:, cost_usd:}}`
  on success or `{:error, reason}` on failure. `cost_usd`, `prompt_tokens`, and
  `completion_tokens` may be nil if OpenRouter doesn't return usage data for the
  selected model. `model` is the resolved model id actually used (echoed by
  OpenRouter, may differ from the request if a fallback fired).
  """
  def complete(prompt, opts \\ []) do
    api_key = Application.get_env(:guild, :openrouter_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      model = Keyword.get(opts, :model) ||
        Application.get_env(:guild, :openrouter_classifier_model, @default_model)

      url = Application.get_env(:guild, :openrouter_api_url, @default_url)

      body = Jason.encode!(%{
        model: model,
        messages: [%{role: "user", content: prompt}],
        max_tokens: 300,
        temperature: 0.1,
        # OpenRouter: opt in to per-request cost reporting in the response usage object.
        usage: %{include: true}
      })

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"HTTP-Referer", "https://guild.inevitable.fyi"}
      ]

      case HTTPoison.post(url, body, headers, recv_timeout: @timeout_ms, timeout: @timeout_ms) do
        {:ok, %{status_code: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]} = decoded} ->
              usage = Map.get(decoded, "usage", %{})
              {:ok, %{
                text: text,
                model: Map.get(decoded, "model") || model,
                prompt_tokens: Map.get(usage, "prompt_tokens"),
                completion_tokens: Map.get(usage, "completion_tokens"),
                cost_usd: Map.get(usage, "cost") || Map.get(usage, "total_cost")
              }}
            {:ok, other} ->
              Logger.warning("OpenRouter: unexpected response shape: #{inspect(other)}")
              {:error, {:unexpected_shape, other}}
            {:error, _} ->
              {:error, :invalid_json}
          end

        {:ok, %{status_code: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status_code: status}} when status >= 500 ->
          {:error, {:server_error, status}}

        {:ok, %{status_code: status}} ->
          {:error, {:http_error, status}}

        {:error, %HTTPoison.Error{reason: :timeout}} ->
          {:error, :timeout}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, {:transport_error, reason}}
      end
    end
  end
end
