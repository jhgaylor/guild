defmodule Guild.Retention do
  @moduledoc """
  Retention policy for decisions_log.

  Implements ADR 0009 (G4 update): keep full rows for the most recent
  @max_rows decisions per thread; null context_snapshot on older rows
  while preserving decision_type, params, reasoning, and timestamps.
  """

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.DecisionsLog

  @max_rows 200

  @doc """
  Null out context_snapshot on all but the most recent @max_rows decisions
  for the given thread_id. Returns {:ok, count_updated}.
  """
  def trim_decisions_log(thread_id) do
    keep_ids =
      Repo.all(
        from d in DecisionsLog,
          where: d.thread_id == ^thread_id,
          order_by: [desc: d.id],
          limit: @max_rows,
          select: d.id
      )

    {count, _} =
      Repo.update_all(
        from(d in DecisionsLog,
          where: d.thread_id == ^thread_id and d.id not in ^keep_ids),
        set: [context_snapshot: nil]
      )

    {:ok, count}
  end
end
