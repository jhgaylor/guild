defmodule Guild.Schema.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_states ~w(unnoticed noticed claimed executing pr_open planned blocked done abandoned)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "threads" do
    field :anchor_type, :string
    field :anchor_id, :string
    field :anchor_url, :string
    field :state, :string
    field :owner, :string
    field :parent_thread_id, :binary_id
    field :linear_issue_id, :string
    field :last_alerted_at, :utc_datetime
    field :held, :boolean, default: false

    has_many :events, Guild.Schema.Event, foreign_key: :thread_id
    has_many :context_notes, Guild.Schema.ContextNote, foreign_key: :thread_id
    has_many :decisions_log, Guild.Schema.DecisionsLog, foreign_key: :thread_id
    has_many :artifacts, Guild.Schema.Artifact, foreign_key: :thread_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:anchor_type, :anchor_id, :anchor_url, :state, :owner, :parent_thread_id, :linear_issue_id, :last_alerted_at, :held])
    |> validate_required([:anchor_type, :anchor_id, :state])
    |> validate_inclusion(:state, @valid_states)
    |> unique_constraint([:anchor_type, :anchor_id])
  end
end
