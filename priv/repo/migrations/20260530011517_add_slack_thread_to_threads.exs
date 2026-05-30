defmodule Guild.Repo.Migrations.AddSlackThreadToThreads do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:threads) do
      add :slack_thread_ts, :string, null: true
      add :slack_channel, :string, null: true
    end

    create index(:threads, [:slack_channel, :slack_thread_ts])

    flush()

    # Backfill: for each thread that has a slack_message artifact with a
    # "slack://channel/ts" url, parse the earliest one and populate the columns.
    threads_with_slack =
      Guild.Repo.all(
        from t in "threads",
          join: a in "artifacts",
          on:
            a.thread_id == t.id and
              a.artifact_type == "slack_message" and
              like(a.url, "slack://%"),
          where: is_nil(t.slack_thread_ts),
          select: %{id: t.id, url: a.url, inserted_at: a.inserted_at},
          order_by: [asc: a.inserted_at]
      )

    # Group by thread_id, keeping the earliest artifact per thread
    earliest_by_thread =
      Enum.reduce(threads_with_slack, %{}, fn row, acc ->
        Map.put_new(acc, row.id, row.url)
      end)

    Enum.each(earliest_by_thread, fn {thread_id, url} ->
      # url format: "slack://channel/ts"
      rest = String.replace_prefix(url, "slack://", "")
      [channel | ts_parts] = String.split(rest, "/")
      ts = Enum.join(ts_parts, "/")

      Guild.Repo.update_all(
        from(t in "threads", where: t.id == ^thread_id),
        set: [slack_channel: channel, slack_thread_ts: ts]
      )
    end)
  end

  def down do
    drop index(:threads, [:slack_channel, :slack_thread_ts])

    alter table(:threads) do
      remove :slack_thread_ts
      remove :slack_channel
    end
  end
end
