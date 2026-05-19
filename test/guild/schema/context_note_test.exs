defmodule Guild.Schema.ContextNoteTest do
  use Guild.DataCase, async: true

  alias Guild.Schema.{ContextNote, Thread}

  defp insert_thread! do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "I_cn_#{System.unique_integer([:positive])}",
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
        note_type: "decision",
        body: "Decided to implement via PR."
      }

      assert %{valid?: true} = ContextNote.changeset(%ContextNote{}, attrs)
    end

    test "invalid without thread_id" do
      attrs = %{note_type: "decision", body: "some body"}
      changeset = ContextNote.changeset(%ContextNote{}, attrs)
      assert %{thread_id: [_ | _]} = errors_on(changeset)
    end

    test "invalid without note_type" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, body: "some body"}
      changeset = ContextNote.changeset(%ContextNote{}, attrs)
      assert %{note_type: [_ | _]} = errors_on(changeset)
    end

    test "invalid without body" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, note_type: "decision"}
      changeset = ContextNote.changeset(%ContextNote{}, attrs)
      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "rejects invalid note_type" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, note_type: "memo", body: "body"}
      changeset = ContextNote.changeset(%ContextNote{}, attrs)
      assert %{note_type: [_ | _]} = errors_on(changeset)
    end

    test "accepts all five valid note_types" do
      thread = insert_thread!()

      for note_type <- ~w(decision attempt blocker status human_instruction) do
        attrs = %{thread_id: thread.id, note_type: note_type, body: "body"}
        assert %{valid?: true} = ContextNote.changeset(%ContextNote{}, attrs)
      end
    end
  end
end
