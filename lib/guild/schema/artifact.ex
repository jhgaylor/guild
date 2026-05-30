defmodule Guild.Schema.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    field :thread_id, :binary_id
    field :artifact_type, :string
    field :source, :string
    field :external_id, :string
    field :url, :string
    field :metadata, :map
    field :terminated, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:thread_id, :artifact_type, :source, :external_id, :url, :metadata, :terminated])
    |> validate_required([:thread_id, :artifact_type, :source, :external_id])
    |> unique_constraint([:source, :external_id])
  end
end
