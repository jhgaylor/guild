defmodule Guild.Repo.Migrations.AddLastAlertedAtToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :last_alerted_at, :utc_datetime, null: true
    end
  end
end
