defmodule Guild.Repo.Migrations.CreateSlackChannels do
  use Ecto.Migration

  def change do
    create table(:slack_channels, primary_key: false) do
      add :channel_id, :string, primary_key: true
      add :default_repo, :string, null: true  # FK-like reference to repos.full_name; nullable
      add :enabled, :boolean, null: false, default: true
      add :notes, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # No foreign key constraint — repos table uses a string PK; keep it loose.
    create index(:slack_channels, [:enabled])
  end
end
