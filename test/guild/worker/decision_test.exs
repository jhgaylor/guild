defmodule Guild.Worker.DecisionTest do
  use ExUnit.Case, async: true

  alias Guild.Worker.Decision

  describe "validate/1" do
    test "rejects nil reasoning" do
      decision = %Decision{action: :implement, reasoning: nil, params: %{}}
      assert {:error, :missing_reasoning} = Decision.validate(decision)
    end

    test "rejects empty string reasoning" do
      decision = %Decision{action: :implement, reasoning: "", params: %{}}
      assert {:error, :missing_reasoning} = Decision.validate(decision)
    end

    test "rejects invalid action atom" do
      decision = %Decision{action: :fly_to_moon, reasoning: "because", params: %{}}
      assert {:error, :invalid_action} = Decision.validate(decision)
    end

    test "rejects nil action" do
      decision = %Decision{action: nil, reasoning: "some reason", params: %{}}
      assert {:error, :invalid_action} = Decision.validate(decision)
    end

    test "accepts valid :implement decision" do
      decision = %Decision{action: :implement, reasoning: "the work is clear", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :plan decision" do
      decision = %Decision{action: :plan, reasoning: "too large for one PR", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :ask_question decision" do
      decision = %Decision{action: :ask_question, reasoning: "need clarification", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :comment decision" do
      decision = %Decision{action: :comment, reasoning: "acknowledging update", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :claim decision" do
      decision = %Decision{action: :claim, reasoning: "fits my scope", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :ignore decision" do
      decision = %Decision{action: :ignore, reasoning: "not relevant to this worker", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "accepts valid :escalate decision" do
      decision = %Decision{action: :escalate, reasoning: "blocked and cannot proceed", params: %{}}
      assert {:ok, ^decision} = Decision.validate(decision)
    end

    test "reasoning check takes priority over action check" do
      # nil reasoning should fail before invalid action is checked
      decision = %Decision{action: :fly_to_moon, reasoning: nil, params: %{}}
      assert {:error, :missing_reasoning} = Decision.validate(decision)
    end
  end
end
