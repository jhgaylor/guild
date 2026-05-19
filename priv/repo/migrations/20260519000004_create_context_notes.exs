defmodule Guild.Repo.Migrations.CreateContextNotes do
  use Ecto.Migration

  def change do
    create table(:context_notes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false
      add :note_type, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:context_notes, [:thread_id, :inserted_at])
    create index(:context_notes, [:thread_id, :note_type])
  end
end
