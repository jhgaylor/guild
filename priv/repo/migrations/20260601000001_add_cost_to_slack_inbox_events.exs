defmodule Guild.Repo.Migrations.AddCostToSlackInboxEvents do
  use Ecto.Migration

  def change do
    alter table(:slack_inbox_events) do
      add :model, :string, null: true
      add :prompt_tokens, :integer, null: true
      add :completion_tokens, :integer, null: true
      add :cost_usd, :float, null: true
    end
  end
end
