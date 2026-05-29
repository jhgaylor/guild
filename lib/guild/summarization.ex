defmodule Guild.Summarization do
  @moduledoc """
  Context-note summarization.

  Implements ADR 0007 (G4 update): trigger summarization when a thread's
  context_notes count exceeds @threshold. Dispatches a Fountain conversation
  with the assembled context, stores the response as a :summary note, and
  marks all previous non-summary notes as :archived.
  """

  require Logger
  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.ContextNote

  @threshold 50

  @doc """
  Summarize a thread's context notes if they exceed the threshold.
  Returns :ok in all cases (errors are logged, not raised).
  """
  def maybe_summarize(thread_id) do
    count =
      Repo.one(
        from n in ContextNote,
          where: n.thread_id == ^thread_id,
          select: count()
      )

    if count > @threshold do
      do_summarize(thread_id)
    else
      :ok
    end
  end

  defp do_summarize(thread_id) do
    agent_id = Application.get_env(:guild, :guild_implementer_agent_id)

    with {:ok, packet} <- Guild.ContextAssembly.build(thread_id),
         prompt = build_prompt(packet),
         {:ok, %{id: conv_id}} <-
           Guild.Adapters.Fountain.dispatch_conversation(agent_id, nil, prompt),
         {:ok, summary_text} <- Guild.Adapters.Fountain.observe_conversation(conv_id) do
      Repo.transaction(fn ->
        Repo.insert!(
          ContextNote.changeset(%ContextNote{}, %{
            thread_id: thread_id,
            note_type: "summary",
            body: summary_text
          })
        )

        Repo.update_all(
          from(n in ContextNote,
            where:
              n.thread_id == ^thread_id and
                n.note_type not in ["summary", "archived"]),
          set: [note_type: "archived"]
        )
      end)

      :ok
    else
      error ->
        Logger.warning(
          "Guild.Summarization: summarization failed for thread #{thread_id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp build_prompt(packet) do
    history_count = length(packet.history)
    notes_count = length(packet.worker_notes)

    """
    Summarize the following thread context concisely for continued work.

    Work item: #{inspect(packet.work_item)}

    Recent history (#{history_count} events):
    #{Enum.map_join(packet.history, "\n", fn e -> "- [#{e.event_type}] #{e.occurred_at}" end)}

    Worker notes (#{notes_count}):
    #{Enum.map_join(packet.worker_notes, "\n", fn n -> "- #{n.note_type}: #{n.body}" end)}

    Provide a concise summary that captures the current state and important context.
    """
  end
end
