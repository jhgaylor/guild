defmodule Guild.Schema.ContextNote do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_note_types ~w(decision attempt blocker status human_instruction summary archived)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "context_notes" do
    field :thread_id, :binary_id
    field :note_type, :string
    field :body, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(context_note, attrs) do
    context_note
    |> cast(attrs, [:thread_id, :note_type, :body])
    |> validate_required([:thread_id, :note_type, :body])
    |> validate_inclusion(:note_type, @valid_note_types)
  end
end
