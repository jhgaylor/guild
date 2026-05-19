defmodule Guild.Repo.Migrations.CreateThreads do
  use Ecto.Migration

  def change do
    create table(:threads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :anchor_type, :string, null: false
      add :anchor_id, :string, null: false
      add :anchor_url, :text
      add :state, :string, null: false, default: "unnoticed"
      add :owner, :string
      add :parent_thread_id, references(:threads, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:threads, [:anchor_type, :anchor_id])
    create index(:threads, [:state])
    create index(:threads, [:owner, :state])
    create index(:threads, [:parent_thread_id])
  end
end
