defmodule Guild.Schema.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "events" do
    field :source, :string
    field :event_type, :string
    field :occurred_at, :utc_datetime_usec
    field :actor_id, :string
    field :actor_type, :string
    field :subject_id, :string
    field :subject_type, :string
    field :thread_id, :binary_id
    field :raw_payload, :map
    field :idempotency_key, :string
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :source,
      :event_type,
      :occurred_at,
      :actor_id,
      :actor_type,
      :subject_id,
      :subject_type,
      :thread_id,
      :raw_payload,
      :idempotency_key
    ])
    |> validate_required([:source, :event_type, :occurred_at, :raw_payload, :idempotency_key])
    |> unique_constraint(:idempotency_key)
  end
end
