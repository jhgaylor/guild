defmodule Guild.RetentionTest do
  use Guild.DataCase, async: true

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Retention
  alias Guild.Schema.{Thread, DecisionsLog}

  defp insert_thread! do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "I_ret_#{System.unique_integer([:positive])}",
        state: "done"
      })
      |> Repo.insert()

    thread
  end

  defp insert_decision!(thread_id, context_snapshot \\ %{"data" => "snapshot"}) do
    Repo.insert!(%DecisionsLog{
      thread_id: thread_id,
      decision_type: "implement",
      reasoning: "test",
      context_snapshot: context_snapshot
    })
  end

  describe "trim_decisions_log/1" do
    test "no-ops when thread has 200 or fewer rows" do
      thread = insert_thread!()
      for _ <- 1..5, do: insert_decision!(thread.id)

      assert {:ok, 0} = Retention.trim_decisions_log(thread.id)

      rows = Repo.all(from d in DecisionsLog, where: d.thread_id == ^thread.id)
      assert Enum.all?(rows, fn r -> r.context_snapshot != nil end)
    end

    test "nulls context_snapshot on rows beyond the most recent 200" do
      thread = insert_thread!()
      for i <- 1..205, do: insert_decision!(thread.id, %{"i" => i})

      assert {:ok, 5} = Retention.trim_decisions_log(thread.id)

      rows =
        Repo.all(
          from d in DecisionsLog,
            where: d.thread_id == ^thread.id,
            order_by: [desc: d.id]
        )

      {kept, trimmed} = Enum.split(rows, 200)
      assert Enum.all?(kept, fn r -> r.context_snapshot != nil end)
      assert Enum.all?(trimmed, fn r -> r.context_snapshot == nil end)
    end

    test "preserves decision_type and reasoning on trimmed rows" do
      thread = insert_thread!()
      for _ <- 1..205, do: insert_decision!(thread.id)

      Retention.trim_decisions_log(thread.id)

      trimmed =
        Repo.all(
          from d in DecisionsLog,
            where: d.thread_id == ^thread.id and is_nil(d.context_snapshot)
        )

      assert Enum.all?(trimmed, fn r -> r.decision_type == "implement" end)
      assert Enum.all?(trimmed, fn r -> r.reasoning == "test" end)
    end

    test "only affects the given thread_id" do
      thread_a = insert_thread!()
      thread_b = insert_thread!()
      for _ <- 1..205, do: insert_decision!(thread_a.id)
      for _ <- 1..5, do: insert_decision!(thread_b.id)

      Retention.trim_decisions_log(thread_a.id)

      b_rows = Repo.all(from d in DecisionsLog, where: d.thread_id == ^thread_b.id)
      assert Enum.all?(b_rows, fn r -> r.context_snapshot != nil end)
    end
  end
end
