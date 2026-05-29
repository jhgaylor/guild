defmodule Guild.Repo.Migrations.AddHeldToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :held, :boolean, default: false, null: false
    end
  end
end
