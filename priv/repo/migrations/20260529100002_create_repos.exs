defmodule Guild.Repo.Migrations.CreateRepos do
  use Ecto.Migration

  def change do
    create table(:repos, primary_key: false) do
      add :full_name, :string, primary_key: true
      add :enabled, :boolean, null: false, default: true
      add :worker_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repos, [:full_name])
    create index(:repos, [:worker_id])
    create index(:repos, [:enabled])
  end
end
