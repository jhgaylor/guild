defmodule Guild.Repo.Migrations.AddStateEnteredAtToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :state_entered_at, :utc_datetime_usec, null: true
    end
  end
end
