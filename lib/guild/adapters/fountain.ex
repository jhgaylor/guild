defmodule Guild.Adapters.Fountain do
  @moduledoc """
  Fountain adapter for worker execution dispatch.
  Implements the five primitives from ADR 0004.

  Reads FOUNTAIN_BASE_URL and FOUNTAIN_TOKEN from config or environment.
  Error tier mapping per ADR 0008:
    - HTTP 4xx → :permanent
    - HTTP 5xx → :transient
    - Network errors → :transient
    - Unexpected response shapes → :unexpected
  """

  defp base_url do
    Application.get_env(:guild, :fountain_base_url) ||
      System.get_env("FOUNTAIN_BASE_URL") ||
      raise "FOUNTAIN_BASE_URL not configured"
  end

  defp token do
    Application.get_env(:guild, :fountain_token) ||
      System.get_env("FOUNTAIN_TOKEN") ||
      raise "FOUNTAIN_TOKEN not configured"
  end

  defp auth_headers do
    [
      {"Authorization", "Bearer #{token()}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp url(path) do
    base = base_url()

    base =
      if String.starts_with?(base, "http"),
        do: base,
        else: "https://#{base}"

    base = String.trim_trailing(base, "/")
    "#{base}#{path}"
  end

  defp map_http_error(429), do: :transient
  defp map_http_error(status) when status >= 500, do: :transient
  defp map_http_error(status) when status >= 400, do: :permanent

  defp decode_response(response) do
    case Jason.decode(response.body) do
      {:ok, body} -> {:ok, body}
      {:error, _} -> {:error, :unexpected, :invalid_json}
    end
  end

  @doc """
  Dispatch a new Fountain conversation.

  Returns {:ok, %{id: conv_id}} | {:error, tier, reason}.
  """
  def dispatch_conversation(agent_id, vault_id \\ nil, prompt, parent_conv_id \\ nil) do
    body =
      %{agent_id: agent_id, prompt: prompt}
      |> maybe_put(:vault_id, vault_id)
      |> Jason.encode!()

    headers =
      case parent_conv_id do
        nil -> auth_headers()
        id -> [{"X-Fountain-Parent-Conversation-Id", id} | auth_headers()]
      end

    try do
      case HTTPoison.post(url("/api/conversations"), body, headers) do
        {:ok, %{status_code: status} = response} when status in 200..299 ->
          with {:ok, decoded} <- decode_response(response),
               %{"data" => %{"id" => id}} <- decoded do
            {:ok, %{id: id}}
          else
            _ -> {:error, :unexpected, :unexpected_response_shape}
          end

        {:ok, %{status_code: status}} ->
          {:error, map_http_error(status), {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Send a follow-up prompt to an existing conversation.

  Returns {:ok, :sent} | {:error, tier, reason}.
  """
  def send_prompt(conv_id, prompt) do
    body = Jason.encode!(%{prompt: prompt})

    try do
      case HTTPoison.post(url("/api/conversations/#{conv_id}/prompts"), body, auth_headers()) do
        {:ok, %{status_code: status}} when status in 200..299 ->
          {:ok, :sent}

        {:ok, %{status_code: status}} ->
          {:error, map_http_error(status), {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Observe a conversation via SSE stream, collecting the final result text.

  Returns {:ok, result_text} | {:error, tier, reason}.
  """
  def observe_conversation(conv_id) do
    stream_url = url("/api/conversations/#{conv_id}/stream?streams=stdout&wait=false")

    try do
      case HTTPoison.get(stream_url, auth_headers(), recv_timeout: 30_000) do
        {:ok, %{status_code: status} = response} when status in 200..299 ->
          text = parse_sse_text(response.body)
          {:ok, text}

        {:ok, %{status_code: status}} ->
          {:error, map_http_error(status), {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Get the current status of a conversation.

  Returns {:ok, status_atom} where status_atom in [:pending, :running, :idle, :terminated]
  | {:error, tier, reason}.
  """
  def get_status(conv_id) do
    try do
      case HTTPoison.get(url("/api/conversations/#{conv_id}"), auth_headers()) do
        {:ok, %{status_code: status} = response} when status in 200..299 ->
          with {:ok, decoded} <- decode_response(response),
               %{"data" => %{"status" => status_str}} <- decoded,
               {:ok, status_atom} <- parse_status(status_str) do
            {:ok, status_atom}
          else
            _ -> {:error, :unexpected, :unexpected_response_shape}
          end

        {:ok, %{status_code: status}} ->
          {:error, map_http_error(status), {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Terminate a conversation.

  Returns {:ok, :terminated} | {:error, tier, reason}.
  """
  def terminate_conversation(conv_id) do
    try do
      case HTTPoison.post(
             url("/api/conversations/#{conv_id}/terminate"),
             "",
             auth_headers()
           ) do
        {:ok, %{status_code: status}} when status in 200..299 ->
          {:ok, :terminated}

        {:ok, %{status_code: status}} ->
          {:error, map_http_error(status), {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status("running"), do: {:ok, :running}
  defp parse_status("idle"), do: {:ok, :idle}
  defp parse_status("terminated"), do: {:ok, :terminated}
  defp parse_status(other), do: {:error, :unexpected, {:unknown_status, other}}

  defp parse_sse_text(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.join("")
  end
end
