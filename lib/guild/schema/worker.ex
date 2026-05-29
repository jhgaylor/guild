defmodule Guild.Schema.Worker do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:worker_id, :string, autogenerate: false}

  schema "workers" do
    field :fountain_agent_id, :string
    field :vault_id, :string
    field :github_installation_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:worker_id, :fountain_agent_id, :vault_id, :github_installation_id])
    |> validate_required([:worker_id, :fountain_agent_id, :vault_id])
  end
end
