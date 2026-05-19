defmodule Guild.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false
      add :artifact_type, :string, null: false
      add :source, :string, null: false
      add :external_id, :string, null: false
      add :url, :string
      add :metadata, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:artifacts, [:source, :external_id])
    create index(:artifacts, [:thread_id, :artifact_type])
  end
end
