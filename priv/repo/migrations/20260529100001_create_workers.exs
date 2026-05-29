defmodule Guild.Repo.Migrations.CreateWorkers do
  use Ecto.Migration

  def change do
    create table(:workers, primary_key: false) do
      add :worker_id, :string, primary_key: true
      add :fountain_agent_id, :string, null: false
      add :vault_id, :string, null: false
      add :github_installation_id, :string, null: true

      timestamps(type: :utc_datetime_usec)
    end
  end
end
