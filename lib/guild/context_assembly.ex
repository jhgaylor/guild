defmodule Guild.ContextAssembly do
  @moduledoc """
  Assembles a ContextPacket for a thread from the database.

  Uses a bounded recency window for events (last 50) plus all human_instruction context notes
  unconditionally. See decisions/0007-context-assembly-strategy.md.
  """

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.{Event, ContextNote, Thread}
  alias Guild.Worker.ContextPacket

  @doc """
  Build a ContextPacket for the given thread_id.

  Returns {:ok, %ContextPacket{}} or {:error, :thread_not_found}.
  """
  def build(thread_id) do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :thread_not_found}

      thread ->
        work_item = %{
          anchor_type: thread.anchor_type,
          anchor_id: thread.anchor_id,
          state: thread.state,
          owner: thread.owner
        }

        # TODO(summarization): revisit when thread length forces it — see decisions/0007
        history =
          Repo.all(
            from e in Event,
              where: e.thread_id == ^thread_id,
              order_by: [desc: e.occurred_at],
              limit: 50
          )

        worker_notes =
          Repo.all(
            from n in ContextNote,
              where: n.thread_id == ^thread_id and n.note_type == "human_instruction"
          )

        packet = %ContextPacket{
          work_item: work_item,
          history: history,
          artifacts: [],
          conversations: [],
          worker_notes: worker_notes,
          current_event: nil
        }

        {:ok, packet}
    end
  end
end
