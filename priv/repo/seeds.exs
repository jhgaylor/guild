# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Guild.Repo.insert!(%Guild.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Seed the default worker row from environment variables.
# GUILD_IMPLEMENTER_AGENT_ID and GUILD_WORKER_VAULT_ID become seed
# values that populate the "default" worker row, preserving backward
# compatibility with single-worker deployments.
default_worker_id = "default"
fountain_agent_id = System.get_env("GUILD_IMPLEMENTER_AGENT_ID") || raise "GUILD_IMPLEMENTER_AGENT_ID not set"
vault_id = System.get_env("GUILD_WORKER_VAULT_ID") || raise "GUILD_WORKER_VAULT_ID not set"
github_installation_id = System.get_env("GITHUB_APP_INSTALLATION_ID")

Guild.Repo.insert!(
  %Guild.Schema.Worker{
    worker_id: default_worker_id,
    fountain_agent_id: fountain_agent_id,
    vault_id: vault_id,
    github_installation_id: github_installation_id
  },
  on_conflict: :nothing,
  conflict_target: :worker_id
)

# Seed the default repo row pointing to the Guild self-hosting repository.
Guild.Repo.insert!(
  %Guild.Schema.Repo{
    full_name: "jhgaylor/guild",
    enabled: true,
    worker_id: default_worker_id
  },
  on_conflict: :nothing,
  conflict_target: :full_name
)
