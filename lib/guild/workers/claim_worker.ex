defmodule Guild.Workers.ClaimWorker do
  @moduledoc """
  Oban worker that durably processes GitHub issue claim requests.

  Jobs are enqueued by the webhook controller when a bot-ready issue event
  arrives. Oban handles retries with backoff on transient failures.
  Uniqueness constraints prevent duplicate jobs for the same issue.
  """

  use Oban.Worker,
    queue: :claims,
    unique: [fields: [:args], period: 60]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repo" => repo, "issue_number" => issue_number} = args}) do
    worker_id = Map.get(args, "worker_id")

    case Guild.Claiming.claim_issue(repo, issue_number, worker_id) do
      {:ok, %{thread: thread, fountain_conv_id: conv_id}} ->
        Logger.info("Claimed issue #{repo}##{issue_number}: thread=#{thread.id} conv=#{conv_id}")
        :ok

      {:error, :already_claimed} ->
        Logger.info("Issue #{repo}##{issue_number} already claimed, cancelling job")
        {:cancel, :already_claimed}

      {:error, reason} ->
        Logger.error("Failed to claim issue #{repo}##{issue_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
