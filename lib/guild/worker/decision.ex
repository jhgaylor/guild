defmodule Guild.Worker.Decision do
  @moduledoc """
  The structured decision returned by a worker implementation.
  validate/1 must pass before Guild routes the decision to the action layer.
  """

  @valid_actions [:implement, :plan, :ask_question, :comment, :claim, :ignore, :escalate]

  defstruct [:action, :reasoning, :params]

  @doc """
  Validates a Decision struct.

  Returns {:ok, decision} if valid.
  Returns {:error, :missing_reasoning} if reasoning is nil or empty string.
  Returns {:error, :invalid_action} if action is not a recognized atom.
  """
  def validate(%__MODULE__{reasoning: r}) when is_nil(r) or r == "",
    do: {:error, :missing_reasoning}

  def validate(%__MODULE__{action: a}) when a not in @valid_actions,
    do: {:error, :invalid_action}

  def validate(%__MODULE__{} = d), do: {:ok, d}

  @doc "Returns the list of valid action atoms."
  def valid_actions, do: @valid_actions
end
