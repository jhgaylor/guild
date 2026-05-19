defmodule Guild.ContextAssemblyTest do
  use Guild.DataCase, async: true

  alias Guild.Repo
  alias Guild.Schema.{Thread, Event, ContextNote}
  alias Guild.ContextAssembly

  # Helpers to insert test data

  defp insert_thread(attrs \\ %{}) do
    defaults = %{
      anchor_type: "github_issue",
      anchor_id: "issue_#{System.unique_integer([:positive])}",
      anchor_url: "https://github.com/test/repo/issues/1",
      state: "noticed",
      owner: "guild-bot"
    }

    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    thread
  end

  defp insert_event(thread_id, occurred_at, suffix \\ nil) do
    key = "github:issues.assigned:#{System.unique_integer([:positive])}#{suffix}"

    {:ok, event} =
      %Event{}
      |> Event.changeset(%{
        source: "github",
        event_type: "issues.assigned",
        occurred_at: occurred_at,
        thread_id: thread_id,
        raw_payload: %{"id" => key},
        idempotency_key: key
      })
      |> Repo.insert()

    event
  end

  defp insert_context_note(thread_id, note_type, body \\ "test note") do
    {:ok, note} =
      %ContextNote{}
      |> ContextNote.changeset(%{
        thread_id: thread_id,
        note_type: note_type,
        body: body
      })
      |> Repo.insert()

    note
  end

  describe "build/1 with 60-event fixture" do
    setup do
      thread = insert_thread()

      # Insert 60 events with sequential occurred_at timestamps
      # Event 1 is oldest, event 60 is most recent
      base = ~U[2026-01-01 00:00:00.000000Z]

      events =
        for i <- 1..60 do
          occurred_at = DateTime.add(base, i * 60, :second)
          insert_event(thread.id, occurred_at)
        end

      # 3 human_instruction notes (2 "old", 1 recent — all must appear)
      note1 = insert_context_note(thread.id, "human_instruction", "old instruction 1")
      note2 = insert_context_note(thread.id, "human_instruction", "old instruction 2")
      note3 = insert_context_note(thread.id, "human_instruction", "recent instruction")

      # 2 notes of other types — must NOT appear in worker_notes
      insert_context_note(thread.id, "decision", "some decision")
      insert_context_note(thread.id, "status", "some status")

      %{thread: thread, events: events, notes: [note1, note2, note3]}
    end

    test "returns exactly 50 history entries (most recent 50 of 60)", %{thread: thread, events: events} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert length(packet.history) == 50

      # The 50 most recent events are events 11..60 (indices 10..59)
      expected_keys =
        events
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
        |> Enum.take(50)
        |> Enum.map(& &1.idempotency_key)
        |> MapSet.new()

      returned_keys = packet.history |> Enum.map(& &1.idempotency_key) |> MapSet.new()
      assert returned_keys == expected_keys
    end

    test "history is ordered most recent first", %{thread: thread} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      timestamps = Enum.map(packet.history, & &1.occurred_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "returns all 3 human_instruction notes regardless of age", %{thread: thread, notes: notes} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert length(packet.worker_notes) == 3

      returned_ids = packet.worker_notes |> Enum.map(& &1.id) |> MapSet.new()
      expected_ids = notes |> Enum.map(& &1.id) |> MapSet.new()
      assert returned_ids == expected_ids
    end

    test "worker_notes contains only human_instruction notes", %{thread: thread} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert Enum.all?(packet.worker_notes, &(&1.note_type == "human_instruction"))
    end

    test "work_item contains thread fields", %{thread: thread} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert packet.work_item.anchor_type == thread.anchor_type
      assert packet.work_item.anchor_id == thread.anchor_id
      assert packet.work_item.state == thread.state
      assert packet.work_item.owner == thread.owner
    end

    test "artifacts and conversations are empty stubs", %{thread: thread} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert packet.artifacts == []
      assert packet.conversations == []
    end

    test "current_event is nil", %{thread: thread} do
      {:ok, packet} = ContextAssembly.build(thread.id)
      assert is_nil(packet.current_event)
    end
  end

  describe "build/1 with missing thread" do
    test "returns {:error, :thread_not_found} for unknown UUID" do
      unknown_id = Ecto.UUID.generate()
      assert {:error, :thread_not_found} = ContextAssembly.build(unknown_id)
    end
  end
end
