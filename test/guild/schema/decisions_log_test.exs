defmodule Guild.Schema.DecisionsLogTest do
  use Guild.DataCase, async: true

  alias Guild.Schema.{DecisionsLog, Thread}

  defp insert_thread! do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "I_dl_#{System.unique_integer([:positive])}",
        state: "unnoticed"
      })
      |> Repo.insert()

    thread
  end

  describe "changeset/2" do
    test "valid changeset with required fields" do
      thread = insert_thread!()

      attrs = %{
        thread_id: thread.id,
        decision_type: "implement",
        reasoning: "Issue is well-scoped and ready."
      }

      assert %{valid?: true} = DecisionsLog.changeset(%DecisionsLog{}, attrs)
    end

    test "invalid without thread_id" do
      attrs = %{decision_type: "implement", reasoning: "some reason"}
      changeset = DecisionsLog.changeset(%DecisionsLog{}, attrs)
      assert %{thread_id: [_ | _]} = errors_on(changeset)
    end

    test "invalid without decision_type" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, reasoning: "some reason"}
      changeset = DecisionsLog.changeset(%DecisionsLog{}, attrs)
      assert %{decision_type: [_ | _]} = errors_on(changeset)
    end

    test "invalid without reasoning" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, decision_type: "implement"}
      changeset = DecisionsLog.changeset(%DecisionsLog{}, attrs)
      assert %{reasoning: [_ | _]} = errors_on(changeset)
    end

    test "accepts optional params and context_snapshot" do
      thread = insert_thread!()

      attrs = %{
        thread_id: thread.id,
        decision_type: "plan",
        reasoning: "Breaking into sub-tasks.",
        params: %{"prompt" => "implement foo"},
        context_snapshot: %{"work_item" => %{"title" => "Foo"}}
      }

      assert %{valid?: true} = DecisionsLog.changeset(%DecisionsLog{}, attrs)
    end
  end
end
