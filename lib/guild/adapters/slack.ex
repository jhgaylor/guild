defmodule Guild.Adapters.Slack do
  @moduledoc """
  Slack adapter for posting messages to channels via the Slack Web API.

  Reads SLACK_BOT_TOKEN and SLACK_CHANNEL_ID from environment variables.
  Returns {:ok, :not_configured} gracefully when credentials are absent.
  """

  require Logger

  @slack_api_url "https://slack.com/api/chat.postMessage"

  defp bot_token do
    Application.get_env(:guild, :slack_bot_token) ||
      System.get_env("SLACK_BOT_TOKEN")
  end

  defp default_channel do
    Application.get_env(:guild, :slack_channel_id) ||
      System.get_env("SLACK_CHANNEL_ID")
  end

  defp configured? do
    not is_nil(bot_token()) and not is_nil(default_channel())
  end

  defp api_url do
    Application.get_env(:guild, :slack_api_url, @slack_api_url)
  end

  @doc """
  Post a message to a Slack channel.

  If channel is nil, falls back to SLACK_CHANNEL_ID env var.
  Returns {:ok, :not_configured} when credentials are absent.
  Returns {:ok, response} on success or {:error, tier, reason} on failure.
  """
  def post_message(channel \\ nil, text) do
    unless configured?() do
      {:ok, :not_configured}
    else
      channel = channel || default_channel()

      body =
        Jason.encode!(%{
          channel: channel,
          text: text
        })

      headers = [
        {"Authorization", "Bearer #{bot_token()}"},
        {"Content-Type", "application/json"}
      ]

      try do
        case HTTPoison.post(api_url(), body, headers) do
          {:ok, %{status_code: status} = response} when status in 200..299 ->
            case Jason.decode(response.body) do
              {:ok, %{"ok" => true} = decoded} ->
                {:ok, decoded}

              {:ok, %{"ok" => false, "error" => err}} ->
                Logger.warning("Slack API error: #{err}")
                {:error, :permanent, {:slack_error, err}}

              _ ->
                {:error, :unexpected, :invalid_json}
            end

          {:ok, %{status_code: status}} when status >= 500 ->
            {:error, :transient, {:http_error, status}}

          {:ok, %{status_code: status}} ->
            {:error, :permanent, {:http_error, status}}

          {:error, %HTTPoison.Error{reason: reason}} ->
            {:error, :transient, reason}
        end
      rescue
        e -> {:error, :unexpected, e}
      end
    end
  end
end
