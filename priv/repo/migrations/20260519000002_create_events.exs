defmodule Guild.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source, :string, null: false
      add :event_type, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :actor_id, :string
      add :actor_type, :string
      add :subject_id, :string
      add :subject_type, :string
      add :thread_id, references(:threads, type: :binary_id, on_delete: :nilify_all)
      add :raw_payload, :map, null: false
      add :idempotency_key, :string, null: false
    end

    create unique_index(:events, [:idempotency_key])
    create index(:events, [:thread_id, :occurred_at])
    create index(:events, [:source, :event_type, :occurred_at])
  end
end
