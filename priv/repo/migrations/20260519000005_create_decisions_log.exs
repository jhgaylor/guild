defmodule Guild.Repo.Migrations.CreateDecisionsLog do
  use Ecto.Migration

  def change do
    create table(:decisions_log, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all), null: false
      add :decision_type, :string, null: false
      add :reasoning, :text, null: false
      add :params, :map
      # TODO(retention): revisit at G3 when fleet scale changes the calculus
      add :context_snapshot, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:decisions_log, [:thread_id, :inserted_at])
    create index(:decisions_log, [:decision_type, :inserted_at])
    create index(:decisions_log, [:inserted_at])
  end
end
