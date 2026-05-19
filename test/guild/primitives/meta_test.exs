defmodule Guild.Primitives.MetaTest do
  use Guild.DataCase, async: false

  alias Guild.Primitives.Meta
  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.Schema.ContextNote
  alias Guild.Schema.DecisionsLog

  defp create_thread(state \\ "unnoticed") do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "issue_#{System.unique_integer([:positive])}",
        state: state
      })
      |> Repo.insert()

    thread
  end

  describe "write_thread_note/4" do
    test "inserts a context note and returns {:ok, note}" do
      thread = create_thread()

      assert {:ok, note} =
               Meta.write_thread_note(thread.id, "status", "working on it")

      assert note.thread_id == thread.id
      assert note.note_type == "status"
      assert note.body == "working on it"

      assert Repo.get!(ContextNote, note.id)
    end

    test "returns :unexpected on invalid note_type" do
      thread = create_thread()
      assert {:error, :unexpected, _} = Meta.write_thread_note(thread.id, "invalid_type", "body")
    end
  end

  describe "update_thread_state/2" do
    test "transitions thread state and returns {:ok, new_state}" do
      thread = create_thread("unnoticed")

      assert {:ok, :noticed} = Meta.update_thread_state(thread.id, :event_ingested)

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "noticed"
    end

    test "returns {:error, :permanent, :illegal_transition} for illegal transitions" do
      thread = create_thread("unnoticed")

      assert {:error, :permanent, :illegal_transition} =
               Meta.update_thread_state(thread.id, :pr_opened)
    end

    test "can chain multiple legal transitions" do
      thread = create_thread("unnoticed")
      assert {:ok, :noticed} = Meta.update_thread_state(thread.id, :event_ingested)
      assert {:ok, :claimed} = Meta.update_thread_state(thread.id, :claim)
      assert {:ok, :executing} = Meta.update_thread_state(thread.id, :dispatch)
    end

    test "returns :unexpected when thread not found" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :unexpected, _} = Meta.update_thread_state(fake_id, :event_ingested)
    end
  end

  describe "log_decision/3" do
    test "inserts a decisions_log entry and returns {:ok, decision}" do
      thread = create_thread()

      assert {:ok, decision} =
               Meta.log_decision(thread.id, "action_selected", %{
                 reasoning: "because reasons",
                 params: %{action: "create_branch"}
               })

      assert decision.thread_id == thread.id
      assert decision.decision_type == "action_selected"
      assert decision.reasoning == "because reasons"

      assert Repo.get!(DecisionsLog, decision.id)
    end

    test "returns :unexpected when thread_id is invalid" do
      assert {:error, :unexpected, _} =
               Meta.log_decision(nil, "action_selected", %{reasoning: "r"})
    end
  end
end
