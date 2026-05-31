defmodule Guild.Release do
  @moduledoc """
  Release-time tasks invoked from `bin/guild eval ...` inside the
  container. Mix is not present in releases, so anything that would
  normally run via `mix ecto.migrate` lives here.
  """
  @app :guild

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          default_worker_id = "default"
          fountain_agent_id = System.get_env("GUILD_IMPLEMENTER_AGENT_ID", "")
          vault_id = System.get_env("GUILD_WORKER_VAULT_ID", "")
          github_installation_id = System.get_env("GITHUB_APP_INSTALLATION_ID")
          github_repo = System.get_env("GITHUB_REPO", "jhgaylor/guild")

          if fountain_agent_id != "" do
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

            Guild.Repo.insert!(
              %Guild.Schema.Repo{
                full_name: github_repo,
                enabled: true,
                worker_id: default_worker_id
              },
              on_conflict: :nothing,
              conflict_target: :full_name
            )
          else
            require Logger
            Logger.warning("GUILD_IMPLEMENTER_AGENT_ID not set; skipping default seed rows")
          end
        end)
    end
  end

  def add_repo(full_name, worker_id \\ "default", enabled \\ true) do
    require Logger
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Guild.Repo, fn _repo ->
        changeset =
          Guild.Schema.Repo.changeset(%Guild.Schema.Repo{}, %{
            full_name: full_name,
            worker_id: worker_id,
            enabled: enabled
          })

        case Guild.Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: :full_name
             ) do
          {:ok, _} ->
            Logger.info("add_repo: inserted #{inspect(full_name)} -> worker=#{inspect(worker_id)}")

          {:error, changeset} ->
            Logger.info(
              "add_repo: #{inspect(full_name)} already exists (or changeset error: #{inspect(changeset.errors)})"
            )
        end
      end)

    :ok
  end

  def slack_ping do
    load_app()
    message = "Slack ping from Guild — if you see this, the bot is live."

    case Guild.Adapters.Slack.post_message(nil, message, []) do
      {:ok, :not_configured} ->
        IO.puts("Slack not configured — SLACK_BOT_TOKEN or SLACK_CHANNEL_ID is missing.")
        :error

      {:ok, _} ->
        IO.puts("Slack ping succeeded.")
        :ok

      {:error, _tier, reason} ->
        IO.puts("Slack ping failed: #{inspect(reason)}")
        :error
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
