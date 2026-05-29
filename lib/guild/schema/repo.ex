defmodule Guild.Schema.Repo do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:full_name, :string, autogenerate: false}

  schema "repos" do
    field :enabled, :boolean, default: true
    field :worker_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:full_name, :enabled, :worker_id])
    |> validate_required([:full_name, :worker_id])
  end
end
