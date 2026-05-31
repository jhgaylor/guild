defmodule Guild.Schema.SlackInboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "slack_inbox_events" do
    field :event_id, :string
    field :channel_id, :string
    field :user_id, :string
    field :user_display_name, :string
    field :message_ts, :string
    field :message_text, :string
    field :verdict, :string
    field :confidence, :float
    field :reasoning, :string
    field :thread_id, :binary_id
    field :action_taken, :string
    field :github_issue_url, :string
    field :override_verdict, :string
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :float

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id, :channel_id, :user_id, :user_display_name,
      :message_ts, :message_text, :verdict, :confidence, :reasoning,
      :thread_id, :action_taken, :github_issue_url, :override_verdict,
      :model, :prompt_tokens, :completion_tokens, :cost_usd
    ])
    |> validate_required([:event_id, :channel_id, :user_id, :message_ts])
    |> unique_constraint(:event_id)
  end
end
