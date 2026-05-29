defmodule Guild.Repo.Migrations.AddLinearIssueIdToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :linear_issue_id, :string, null: true
    end
  end
end
