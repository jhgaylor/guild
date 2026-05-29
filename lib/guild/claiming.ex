defmodule Guild.Claiming do
  @moduledoc """
  Core claiming logic: fetch issue, advance thread state machine,
  dispatch Fountain worker, store artifact.
  """

  require Logger

  alias Guild.Repo
  alias Guild.Schema.{Thread, Event, Artifact}
  alias Guild.Primitives.Meta
  alias Guild.Adapters.Fountain
  import Ecto.Query, only: [from: 2]

  @doc """
  Claim a GitHub issue end-to-end:
    1. Fetch issue via GitHub adapter
    2. Upsert Thread (anchor_type: github_issue, anchor_id: issue_number)
    3. Advance state machine: unnoticed → noticed → claimed
    4. Insert seed Event (idempotent via idempotency_key)
    5. Dispatch Fountain conversation (idempotent: skips if artifact exists)
    6. Insert fountain_conversation Artifact
    7. Transition claimed → executing

  Returns {:ok, %{thread: thread, fountain_conv_id: conv_id}} | {:error, reason}.
  """
  def claim_issue(repo, issue_number) do
    with {:ok, issue} <- Guild.GitHub.impl().get_issue(repo, issue_number),
         {:ok, thread} <- claim_with_lock(issue_number),
         {:ok, _event} <- insert_seed_event(repo, issue_number, thread),
         {:ok, conv_id} <- dispatch_and_store(thread, repo, issue_number),
         {:ok, thread} <- transition_to_executing(thread) do
      issue_title = Map.get(issue, "title", "GitHub Issue ##{issue_number} on #{repo}")

      Guild.Adapters.Linear.create_issue(%{
        title: issue_title,
        description: "Tracking thread ##{thread.id} for #{repo}##{issue_number}"
      })

      Guild.Adapters.Linear.update_issue(thread.id, %{stateId: "in_progress"})

      {:ok, %{thread: thread, fountain_conv_id: conv_id}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _tier, reason} -> {:error, reason}
    end
  end

  # --- private helpers ---

  # Wraps check-existing → upsert → claim in a transaction with a PostgreSQL
  # advisory xact lock. If another caller holds the lock for the same thread,
  # pg_try_advisory_xact_lock returns false and we abort with :already_claimed.
  defp claim_with_lock(issue_number) do
    Repo.transaction(fn ->
      {:ok, thread} = upsert_and_fetch_thread(issue_number)

      %{rows: [[locked]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_try_advisory_xact_lock(hashtext($1))",
          [thread.id]
        )

      unless locked, do: Repo.rollback(:already_claimed)

      case advance_to_claimed(thread) do
        {:ok, thread} -> thread
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp upsert_and_fetch_thread(issue_number) do
    anchor_id = to_string(issue_number)
    owner = Application.get_env(:guild, :worker_identity, "guild")

    changeset =
      Thread.changeset(%Thread{}, %{
        anchor_type: "github_issue",
        anchor_id: anchor_id,
        state: "unnoticed",
        owner: owner
      })

    Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:anchor_type, :anchor_id])

    thread =
      Repo.one!(
        from t in Thread,
          where: t.anchor_type == "github_issue" and t.anchor_id == ^anchor_id
      )

    {:ok, thread}
  end

  defp advance_to_claimed(thread) do
    with {:ok, thread} <- maybe_transition(thread, "unnoticed", :event_ingested),
         {:ok, thread} <- maybe_transition(thread, "noticed", :claim) do
      {:ok, thread}
    end
  end

  defp maybe_transition(thread, from_state, event) do
    if thread.state == from_state do
      case Meta.update_thread_state(thread.id, event) do
        {:ok, _} -> {:ok, Repo.get!(Thread, thread.id)}
        {:error, tier, reason} -> {:error, {tier, reason}}
      end
    else
      {:ok, thread}
    end
  end

  defp insert_seed_event(repo, issue_number, thread) do
    attrs = %{
      source: "guild",
      event_type: "issue_claimed",
      occurred_at: DateTime.utc_now(),
      actor_id: "guild",
      thread_id: thread.id,
      idempotency_key: "claim_seed:#{repo}:#{issue_number}",
      raw_payload: %{"repo" => repo, "issue_number" => issue_number}
    }

    changeset = Event.changeset(%Event{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, event} -> {:ok, event}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Idempotent: if a fountain_conversation artifact already exists for this thread,
  # return its conv_id without re-dispatching.
  defp dispatch_and_store(thread, repo, issue_number) do
    case Repo.one(
           from a in Artifact,
             where:
               a.thread_id == ^thread.id and
                 a.artifact_type == "fountain_conversation",
             limit: 1
         ) do
      %Artifact{external_id: conv_id} ->
        {:ok, conv_id}

      nil ->
        agent_id = Application.get_env(:guild, :guild_implementer_agent_id)
        vault_id = Application.get_env(:guild, :worker_vault_id, "")

        prompt =
          "Implement GitHub issue ##{issue_number} on #{repo}. " <>
            "Read the issue, implement, run mix test, open a PR."

        case Fountain.dispatch_conversation(agent_id, vault_id, prompt) do
          {:ok, %{id: conv_id}} ->
            artifact_changeset =
              Artifact.changeset(%Artifact{}, %{
                thread_id: thread.id,
                artifact_type: "fountain_conversation",
                source: "fountain",
                external_id: conv_id
              })

            case Repo.insert(artifact_changeset) do
              {:ok, _} -> {:ok, conv_id}
              {:error, changeset} -> {:error, changeset}
            end

          {:error, tier, reason} ->
            {:error, {tier, reason}}
        end
    end
  end

  defp transition_to_executing(thread) do
    # Re-fetch to get latest state (dispatch_and_store may not have changed it)
    thread = Repo.get!(Thread, thread.id)

    if thread.state == "claimed" do
      case Meta.update_thread_state(thread.id, :dispatch) do
        {:ok, _} -> {:ok, Repo.get!(Thread, thread.id)}
        {:error, tier, reason} -> {:error, {tier, reason}}
      end
    else
      {:ok, thread}
    end
  end
end
