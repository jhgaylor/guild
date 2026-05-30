defmodule Guild.Repo.Migrations.AddTerminatedToArtifacts do
  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      add :terminated, :boolean, default: false, null: false
    end
  end
end
