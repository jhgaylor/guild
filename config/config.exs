# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :guild,
  ecto_repos: [Guild.Repo],
  generators: [timestamp_type: :utc_datetime],
  worker_identity: "guild-bot"

# Configure the endpoint
config :guild, GuildWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GuildWeb.ErrorHTML, json: GuildWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Guild.PubSub,
  live_view: [signing_salt: "Deo0DjhD"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
