defmodule Guild.SlackInbox do
  @moduledoc """
  LLM-based classifier for inbound Slack messages (ADR 0017).
  """

  require Logger

  def classify(%{message: msg, channel_id: ch_id, channel_name: ch_name,
                 user_display_name: display_name, default_repo: default_repo,
                 open_threads: threads}) do
    prompt = build_prompt(msg, ch_name || ch_id, default_repo, display_name, threads)

    case Guild.LLM.OpenRouter.complete(prompt) do
      {:ok, %{text: text} = response} ->
        usage = Map.take(response, [:model, :prompt_tokens, :completion_tokens, :cost_usd])

        case parse_classification(text) do
          {:ok, classification} -> {:ok, Map.merge(classification, usage)}
          other -> other
        end

      {:error, :no_api_key} ->
        {:error, :no_api_key}

      {:error, reason} ->
        Logger.warning("SlackInbox.classify: OpenRouter error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_prompt(message, channel_name, default_repo, user_display_name, open_threads) do
    threads_text =
      if Enum.empty?(open_threads) do
        "(none)"
      else
        open_threads
        |> Enum.take(20)
        |> Enum.map(fn t ->
          "- [#{t.id}] #{t.anchor_id}: #{t.summary} (#{t.state})"
        end)
        |> Enum.join("\n")
      end

    repo_text = default_repo || "not configured"

    """
    You are a work-routing assistant for an autonomous software engineering bot called Guild.
    Guild watches a Slack channel and decides whether each new top-level message represents:
    - "new_work": a request for Guild to perform a software task (fix a bug, add a feature, update docs, etc.)
    - "refers_to_existing": a message referencing work that Guild is already doing or has done
    - "noise": casual conversation, questions not directed at Guild, announcements, etc.

    Channel: ##{channel_name} | Repo: #{repo_text} | User: #{user_display_name}

    Message:
    \"\"\"
    #{String.slice(message, 0, 2000)}
    \"\"\"

    Currently open work threads (most recent first):
    #{threads_text}

    Return ONLY valid JSON. No markdown. No commentary before or after the JSON object.
    {
      "verdict": "new_work" | "refers_to_existing" | "noise",
      "confidence": <float 0.0-1.0>,
      "reasoning": "<200 chars or less explaining your verdict>",
      "matched_thread_id": "<thread UUID if refers_to_existing, else null>"
    }
    """
  end

  defp parse_classification(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, %{"verdict" => verdict, "confidence" => confidence, "reasoning" => reasoning} = decoded}
      when verdict in ["new_work", "refers_to_existing", "noise"] and is_float(confidence) ->
        thread_id = Map.get(decoded, "matched_thread_id")
        {:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: thread_id}}

      {:ok, %{"verdict" => verdict, "confidence" => confidence, "reasoning" => reasoning} = decoded}
      when verdict in ["new_work", "refers_to_existing", "noise"] and is_integer(confidence) ->
        thread_id = Map.get(decoded, "matched_thread_id")
        {:ok, %{verdict: verdict, confidence: confidence / 1.0, reasoning: reasoning, thread_id: thread_id}}

      {:ok, other} ->
        Logger.warning("SlackInbox.classify: unexpected JSON shape: #{inspect(other)}")
        {:ok, %{verdict: "noise", confidence: 0.0,
                reasoning: "Malformed classifier response: #{String.slice(text, 0, 200)}",
                thread_id: nil}}

      {:error, _} ->
        Logger.warning("SlackInbox.classify: non-JSON response: #{String.slice(text, 0, 200)}")
        {:ok, %{verdict: "noise", confidence: 0.0,
                reasoning: "Non-JSON classifier response: #{String.slice(text, 0, 200)}",
                thread_id: nil}}
    end
  end
end
