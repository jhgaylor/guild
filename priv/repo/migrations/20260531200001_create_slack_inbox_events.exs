defmodule Guild.Repo.Migrations.CreateSlackInboxEvents do
  use Ecto.Migration

  def change do
    create table(:slack_inbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :channel_id, :string, null: false
      add :user_id, :string, null: false
      add :user_display_name, :string
      add :message_ts, :string, null: false
      add :message_text, :text
      add :verdict, :string
      add :confidence, :float
      add :reasoning, :text
      add :thread_id, :binary_id, null: true
      add :action_taken, :string, null: true
      add :github_issue_url, :string, null: true
      add :override_verdict, :string, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:slack_inbox_events, [:event_id])
    create index(:slack_inbox_events, [:channel_id, :user_id, :inserted_at])
    create index(:slack_inbox_events, [:thread_id])
  end
end
