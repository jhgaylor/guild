defmodule Guild.Primitives.Meta do
  @moduledoc """
  Meta primitives: thread notes, state transitions, and decision logging.
  Postgres-only; no external HTTP calls.
  """

  alias Guild.Repo
  alias Guild.Schema.ContextNote
  alias Guild.Schema.DecisionsLog
  alias Guild.Schema.Thread
  alias Guild.StateMachine

  @doc """
  Write a context note for a thread.
  Returns {:ok, note} or {:error, :unexpected, reason}.
  """
  def write_thread_note(thread_id, note_type, body, _opts \\ []) do
    try do
      changeset =
        ContextNote.changeset(%ContextNote{}, %{
          thread_id: thread_id,
          note_type: note_type,
          body: body
        })

      case Repo.insert(changeset) do
        {:ok, note} -> {:ok, note}
        {:error, changeset} -> {:error, :unexpected, changeset}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Attempt a state transition on a thread. Delegates to Guild.StateMachine.transition/2.
  On success, updates thread.state in the DB.
  Returns {:ok, new_state} | {:error, :permanent, :illegal_transition} | {:error, :unexpected, reason}.
  """
  def update_thread_state(thread_id, event) do
    try do
      thread = Repo.get!(Thread, thread_id)
      # Ensure StateMachine is loaded so its 9 state atoms are in the table
      # before `String.to_existing_atom/1`. Without this, calling from a
      # cold Mix task path raises ArgumentError (the test suite happens to
      # load StateMachine earlier, masking the bug).
      Code.ensure_loaded(StateMachine)
      current_state = String.to_existing_atom(thread.state)

      case StateMachine.transition(current_state, event) do
        {:ok, new_state} ->
          attrs =
            if new_state in [:done, :abandoned] do
              %{state: to_string(new_state), owner: nil}
            else
              %{state: to_string(new_state)}
            end

          changeset = Thread.changeset(thread, attrs)
          Repo.update!(changeset)
          {:ok, new_state}

        {:error, :illegal_transition} ->
          {:error, :permanent, :illegal_transition}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Log a decision for a thread.
  Returns {:ok, decision} or {:error, :unexpected, reason}.
  """
  def log_decision(thread_id, decision_type, attrs \\ %{}) do
    try do
      changeset =
        DecisionsLog.changeset(%DecisionsLog{}, %{
          thread_id: thread_id,
          decision_type: decision_type,
          reasoning: Map.get(attrs, :reasoning, ""),
          params: Map.get(attrs, :params),
          context_snapshot: Map.get(attrs, :context_snapshot)
        })

      case Repo.insert(changeset) do
        {:ok, decision} -> {:ok, decision}
        {:error, changeset} -> {:error, :unexpected, changeset}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end
end
