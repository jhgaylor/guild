defmodule Guild.Control do
  @moduledoc """
  Operator control plane: hold, resume, and abandon threads via Slack slash commands.
  """

  import Ecto.Query
  require Logger

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.Primitives.Meta

  @doc """
  Hold a thread: set held = true and cancel any pending ClaimWorker Oban jobs.
  Accepts a GitHub issue number (string) or a thread UUID.
  """
  def hold(ref) do
    with {:ok, thread} <- resolve_thread(ref) do
      changeset = Thread.changeset(thread, %{held: true})

      case Repo.update(changeset) do
        {:ok, _updated} ->
          cancel_claim_jobs(thread)
          {:ok, "Thread #{thread.id} is now held. The reconciler will skip it until resumed."}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Resume a held thread: set held = false so the reconciler picks it up again.
  """
  def resume(ref) do
    with {:ok, thread} <- resolve_thread(ref) do
      changeset = Thread.changeset(thread, %{held: false})

      case Repo.update(changeset) do
        {:ok, _updated} ->
          {:ok, "Thread #{thread.id} resumed. The reconciler will pick it up shortly."}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Abandon a thread: transition to the :abandoned terminal state and cancel pending jobs.
  Meta.update_thread_state clears the owner on :abandoned automatically.
  """
  def abandon(ref) do
    with {:ok, thread} <- resolve_thread(ref) do
      case Meta.update_thread_state(thread.id, :abandon) do
        {:ok, :abandoned} ->
          cancel_claim_jobs(thread)
          {:ok, "Thread #{thread.id} has been abandoned."}

        {:error, tier, reason} ->
          {:error, {tier, reason}}
      end
    end
  end

  # Resolve a thread by UUID or GitHub issue number.
  defp resolve_thread(ref) when is_binary(ref) do
    ref = String.trim(ref)

    case Ecto.UUID.cast(ref) do
      {:ok, uuid} ->
        case Repo.get(Thread, uuid) do
          nil -> {:error, :not_found}
          thread -> {:ok, thread}
        end

      :error ->
        # Strip optional leading "#" and treat as GitHub issue anchor_id
        anchor_id = String.trim_leading(ref, "#")

        case Repo.one(
               from t in Thread,
                 where: t.anchor_type == "github_issue" and t.anchor_id == ^anchor_id,
                 limit: 1
             ) do
          nil -> {:error, :not_found}
          thread -> {:ok, thread}
        end
    end
  end

  # Cancel pending ClaimWorker Oban jobs whose args match this thread's anchor_id.
  # Uses Repo.update_all for atomicity and compatibility with the test sandbox.
  defp cancel_claim_jobs(thread) do
    anchor_id = thread.anchor_id
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(j in Oban.Job,
          where:
            j.worker == "Elixir.Guild.Workers.ClaimWorker" and
              j.state in ["available", "scheduled", "retryable"] and
              fragment("?->>'issue_number' = ?", j.args, ^anchor_id)
        ),
        set: [state: "cancelled", cancelled_at: now]
      )

    if count > 0 do
      Logger.info("Control: cancelled #{count} Oban job(s) for thread #{thread.id}")
    end

    :ok
  end
end
