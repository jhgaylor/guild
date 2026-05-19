defmodule Guild.StateMachine do
  @moduledoc """
  Nine-state machine for Guild thread lifecycle.

  Returns {:ok, new_state} for legal transitions and {:error, :illegal_transition} for all others.
  Callers who prefer raise semantics may catch {:error, :illegal_transition} and raise
  IllegalTransitionError themselves, or use the exception directly.
  """

  @active_states [:unnoticed, :noticed, :claimed, :executing, :pr_open, :blocked, :planned]
  @terminal_states [:done, :abandoned]
  @all_states @active_states ++ @terminal_states

  defexception [:message]

  defmodule IllegalTransitionError do
    defexception [:from, :event, :message]

    @impl true
    def exception(opts) do
      from = Keyword.fetch!(opts, :from)
      event = Keyword.fetch!(opts, :event)
      %__MODULE__{from: from, event: event, message: "Illegal transition: #{from} + #{event}"}
    end
  end

  @doc "Returns all non-terminal (active) states."
  def active_states, do: @active_states

  @doc "Returns all valid states."
  def all_states, do: @all_states

  @doc """
  Attempt a state transition.

  Returns `{:ok, new_state}` for legal transitions,
  `{:error, :illegal_transition}` for all others.
  """
  def transition(:unnoticed, :event_ingested), do: {:ok, :noticed}

  def transition(:noticed, :claim), do: {:ok, :claimed}
  def transition(:noticed, :ignore), do: {:ok, :unnoticed}

  def transition(:claimed, :dispatch), do: {:ok, :executing}

  def transition(:executing, :pr_opened), do: {:ok, :pr_open}
  def transition(:executing, :decomposed), do: {:ok, :planned}
  def transition(:executing, :ask_question), do: {:ok, :blocked}

  def transition(:pr_open, :changes_requested), do: {:ok, :executing}
  def transition(:pr_open, :pr_merged), do: {:ok, :done}

  def transition(:blocked, :human_replied), do: {:ok, :executing}

  def transition(:planned, :all_children_done), do: {:ok, :done}

  # Any active (non-terminal) state can be abandoned
  def transition(from, :abandon) when from in @active_states, do: {:ok, :abandoned}

  # All other combinations are illegal
  def transition(_from, _event), do: {:error, :illegal_transition}
end
