defmodule Guild.StateMachineTest do
  use ExUnit.Case, async: true

  alias Guild.StateMachine

  # ── Legal transitions ────────────────────────────────────────────────────────

  describe "legal transitions" do
    test "unnoticed + event_ingested -> noticed" do
      assert {:ok, :noticed} = StateMachine.transition(:unnoticed, :event_ingested)
    end

    test "noticed + claim -> claimed" do
      assert {:ok, :claimed} = StateMachine.transition(:noticed, :claim)
    end

    test "noticed + ignore -> unnoticed" do
      assert {:ok, :unnoticed} = StateMachine.transition(:noticed, :ignore)
    end

    test "claimed + dispatch -> executing" do
      assert {:ok, :executing} = StateMachine.transition(:claimed, :dispatch)
    end

    test "executing + pr_opened -> pr_open" do
      assert {:ok, :pr_open} = StateMachine.transition(:executing, :pr_opened)
    end

    test "executing + decomposed -> planned" do
      assert {:ok, :planned} = StateMachine.transition(:executing, :decomposed)
    end

    test "executing + ask_question -> blocked" do
      assert {:ok, :blocked} = StateMachine.transition(:executing, :ask_question)
    end

    test "pr_open + changes_requested -> executing" do
      assert {:ok, :executing} = StateMachine.transition(:pr_open, :changes_requested)
    end

    test "pr_open + pr_merged -> done" do
      assert {:ok, :done} = StateMachine.transition(:pr_open, :pr_merged)
    end

    test "blocked + human_replied -> executing" do
      assert {:ok, :executing} = StateMachine.transition(:blocked, :human_replied)
    end

    test "planned + all_children_done -> done" do
      assert {:ok, :done} = StateMachine.transition(:planned, :all_children_done)
    end
  end

  # ── Abandon from every active state ─────────────────────────────────────────

  describe "abandon from any active state" do
    for state <- [:unnoticed, :noticed, :claimed, :executing, :pr_open, :blocked, :planned] do
      test "#{state} + abandon -> abandoned" do
        assert {:ok, :abandoned} = StateMachine.transition(unquote(state), :abandon)
      end
    end
  end

  # ── Illegal transitions ──────────────────────────────────────────────────────

  describe "illegal transitions" do
    test "done + anything is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:done, :event_ingested)
      assert {:error, :illegal_transition} = StateMachine.transition(:done, :claim)
      assert {:error, :illegal_transition} = StateMachine.transition(:done, :dispatch)
      assert {:error, :illegal_transition} = StateMachine.transition(:done, :pr_merged)
      assert {:error, :illegal_transition} = StateMachine.transition(:done, :abandon)
    end

    test "abandoned + anything is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:abandoned, :event_ingested)
      assert {:error, :illegal_transition} = StateMachine.transition(:abandoned, :claim)
      assert {:error, :illegal_transition} = StateMachine.transition(:abandoned, :dispatch)
      assert {:error, :illegal_transition} = StateMachine.transition(:abandoned, :abandon)
    end

    test "unnoticed + claim is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:unnoticed, :claim)
    end

    test "unnoticed + dispatch is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:unnoticed, :dispatch)
    end

    test "noticed + dispatch is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:noticed, :dispatch)
    end

    test "noticed + pr_opened is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:noticed, :pr_opened)
    end

    test "claimed + pr_opened is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:claimed, :pr_opened)
    end

    test "claimed + claim is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:claimed, :claim)
    end

    test "executing + claim is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:executing, :claim)
    end

    test "executing + pr_merged is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:executing, :pr_merged)
    end

    test "pr_open + dispatch is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:pr_open, :dispatch)
    end

    test "pr_open + decomposed is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:pr_open, :decomposed)
    end

    test "blocked + pr_merged is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:blocked, :pr_merged)
    end

    test "planned + human_replied is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:planned, :human_replied)
    end

    test "planned + pr_merged is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:planned, :pr_merged)
    end

    test "unknown state + any event is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:nonexistent, :claim)
    end

    test "valid state + unknown event is illegal" do
      assert {:error, :illegal_transition} = StateMachine.transition(:noticed, :nonexistent_event)
    end
  end

  # ── active_states/0 ──────────────────────────────────────────────────────────

  describe "active_states/0" do
    test "returns all non-terminal states" do
      active = StateMachine.active_states()
      assert :unnoticed in active
      assert :noticed in active
      assert :claimed in active
      assert :executing in active
      assert :pr_open in active
      assert :blocked in active
      assert :planned in active
      refute :done in active
      refute :abandoned in active
    end
  end
end
