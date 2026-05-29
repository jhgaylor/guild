defmodule Guild.SummarizationTest do
  use Guild.DataCase, async: false

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Summarization
  alias Guild.Schema.{Thread, ContextNote}

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:guild, :fountain_api_key, "test_token")
    Application.put_env(:guild, :guild_implementer_agent_id, "test-agent-id")

    on_exit(fn ->
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :fountain_api_key)
      Application.delete_env(:guild, :guild_implementer_agent_id)
    end)

    {:ok, bypass: bypass}
  end

  defp insert_thread! do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "I_sum_#{System.unique_integer([:positive])}",
        state: "executing"
      })
      |> Repo.insert()

    thread
  end

  defp insert_notes!(thread_id, count, note_type \\ "status") do
    for i <- 1..count do
      Repo.insert!(%ContextNote{
        thread_id: thread_id,
        note_type: note_type,
        body: "Note #{i}"
      })
    end
  end

  describe "maybe_summarize/1" do
    test "no-ops when note count is at or below threshold" do
      thread = insert_thread!()
      insert_notes!(thread.id, 50)

      assert :ok = Summarization.maybe_summarize(thread.id)

      notes = Repo.all(from n in ContextNote, where: n.thread_id == ^thread.id)
      assert length(notes) == 50
      assert Enum.all?(notes, fn n -> n.note_type == "status" end)
    end

    test "triggers summarization when note count exceeds threshold", %{bypass: bypass} do
      thread = insert_thread!()
      insert_notes!(thread.id, 51)

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{id: "sum-conv-1"}}))
      end)

      Bypass.expect_once(bypass, "GET", "/api/conversations/sum-conv-1/stream", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "data: Thread context summary.\n\n")
      end)

      assert :ok = Summarization.maybe_summarize(thread.id)

      summary =
        Repo.one(
          from n in ContextNote,
            where: n.thread_id == ^thread.id and n.note_type == "summary"
        )

      assert summary != nil
      assert summary.body == "Thread context summary."

      archived =
        Repo.all(
          from n in ContextNote,
            where: n.thread_id == ^thread.id and n.note_type == "archived"
        )

      assert length(archived) == 51
    end

    test "returns :ok and logs warning on Fountain error without crashing", %{bypass: bypass} do
      thread = insert_thread!()
      insert_notes!(thread.id, 55)

      Bypass.expect_once(bypass, "POST", "/api/conversations", fn conn ->
        Plug.Conn.resp(conn, 500, "internal error")
      end)

      assert :ok = Summarization.maybe_summarize(thread.id)

      count =
        Repo.one(
          from n in ContextNote,
            where: n.thread_id == ^thread.id and n.note_type == "summary",
            select: count()
        )

      assert count == 0
    end
  end
end
