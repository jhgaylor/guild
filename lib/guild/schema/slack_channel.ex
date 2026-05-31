defmodule Guild.Schema.SlackChannel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:channel_id, :string, autogenerate: false}

  schema "slack_channels" do
    field :default_repo, :string          # nullable; references repos.full_name
    field :enabled, :boolean, default: true
    field :notes, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(slack_channel, attrs) do
    slack_channel
    |> cast(attrs, [:channel_id, :default_repo, :enabled, :notes])
    |> validate_required([:channel_id])
    |> unique_constraint(:channel_id, name: :slack_channels_pkey)
  end
end
