defmodule Guild.Schema.DecisionsLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "decisions_log" do
    belongs_to :thread, Guild.Schema.Thread, foreign_key: :thread_id, type: :binary_id
    field :decision_type, :string
    field :reasoning, :string
    field :params, :map
    field :context_snapshot, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decisions_log, attrs) do
    decisions_log
    |> cast(attrs, [:thread_id, :decision_type, :reasoning, :params, :context_snapshot])
    |> validate_required([:thread_id, :decision_type, :reasoning])
  end
end
