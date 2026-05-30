defmodule GuildWeb.AdminController do
  use GuildWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    render(conn, :index)
  end

  def repos(conn, _params) do
    render(conn, :repos)
  end

  def workers(conn, _params) do
    render(conn, :workers)
  end

  def integrations(conn, _params) do
    github = github_status()
    slack = slack_status()
    linear = linear_status()
    fountain = fountain_status()

    render(conn, :integrations,
      github: github,
      slack: slack,
      linear: linear,
      fountain: fountain
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers — integration status checks (no live API calls)
  # ---------------------------------------------------------------------------

  defp github_status do
    app_id = System.get_env("GITHUB_APP_ID")
    private_key = System.get_env("GITHUB_PRIVATE_KEY")
    installation_id = System.get_env("GITHUB_INSTALLATION_ID")

    configured? =
      present?(app_id) and present?(private_key) and present?(installation_id)

    last_event =
      Guild.Repo.one(
        from e in Guild.Schema.Event,
          where: e.source == "github",
          order_by: [desc: e.occurred_at],
          limit: 1
      )

    status = if configured?, do: :ready, else: :unconfigured

    {status,
     %{
       app_id_set: present?(app_id),
       private_key_set: present?(private_key),
       installation_id_set: present?(installation_id),
       webhook_secret_set:
         present?(Application.get_env(:guild, :github_webhook_secret)),
       last_event: last_event
     }}
  end

  defp slack_status do
    signing_secret = Application.get_env(:guild, :slack_signing_secret)
    bot_token = Application.get_env(:guild, :slack_bot_token)
    channel_id = Application.get_env(:guild, :slack_channel_id)

    status =
      cond do
        present?(signing_secret) and present?(bot_token) and present?(channel_id) ->
          :ready

        present?(signing_secret) ->
          :partial

        true ->
          :unconfigured
      end

    last_artifact =
      Guild.Repo.one(
        from a in Guild.Schema.Artifact,
          where: a.artifact_type == "slack_message",
          order_by: [desc: a.inserted_at],
          limit: 1
      )

    {status,
     %{
       signing_secret_set: present?(signing_secret),
       bot_token_set: present?(bot_token),
       channel_id_set: present?(channel_id),
       last_artifact: last_artifact
     }}
  end

  defp linear_status do
    api_key = Application.get_env(:guild, :linear_api_key)
    team_id = Application.get_env(:guild, :linear_team_id)
    state_in_progress = Application.get_env(:guild, :linear_state_in_progress_id)
    state_done = Application.get_env(:guild, :linear_state_done_id)

    configured? = present?(api_key) and present?(team_id)
    status = if configured?, do: :ready, else: :unconfigured

    last_thread =
      Guild.Repo.one(
        from t in Guild.Schema.Thread,
          where: not is_nil(t.linear_issue_id),
          order_by: [desc: t.updated_at],
          limit: 1
      )

    {status,
     %{
       api_key_set: present?(api_key),
       team_id_set: present?(team_id),
       state_in_progress_set: present?(state_in_progress),
       state_done_set: present?(state_done),
       last_thread: last_thread
     }}
  end

  defp fountain_status do
    api_key = Application.get_env(:guild, :fountain_api_key)
    base_url = Application.get_env(:guild, :fountain_base_url)
    agent_id = Application.get_env(:guild, :guild_implementer_agent_id)

    configured? = present?(api_key) and present?(base_url) and present?(agent_id)
    status = if configured?, do: :ready, else: :unconfigured

    {status,
     %{
       api_key_set: present?(api_key),
       base_url_set: present?(base_url),
       agent_id_set: present?(agent_id)
     }}
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
