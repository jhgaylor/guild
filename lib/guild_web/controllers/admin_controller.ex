defmodule GuildWeb.AdminController do
  use GuildWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    render(conn, :index)
  end

  def repos(conn, _params) do
    repos = Guild.Repo.all(Guild.Schema.Repo)
    workers = Guild.Repo.all(Guild.Schema.Worker)
    changeset = Ecto.Changeset.change(%Guild.Schema.Repo{})
    render(conn, :repos, repos: repos, workers: workers, changeset: changeset)
  end

  def create_repo(conn, params) do
    full_name = String.trim(params["full_name"] || "")
    worker_id = case String.trim(params["worker_id"] || "") do
      "" -> "default"
      wid -> wid
    end

    if full_name == "" do
      repos = Guild.Repo.all(Guild.Schema.Repo)
      workers = Guild.Repo.all(Guild.Schema.Worker)
      changeset =
        Guild.Schema.Repo.changeset(%Guild.Schema.Repo{}, %{full_name: "", worker_id: worker_id})
        |> Ecto.Changeset.add_error(:full_name, "can't be blank")
        |> Map.put(:action, :insert)
      conn
      |> put_status(200)
      |> render(:repos, repos: repos, workers: workers, changeset: changeset)
    else
      changeset = Guild.Schema.Repo.changeset(%Guild.Schema.Repo{}, %{
        full_name: full_name,
        worker_id: worker_id,
        enabled: true
      })
      Guild.Repo.insert(changeset, on_conflict: :nothing, conflict_target: :full_name)
      redirect(conn, to: ~p"/admin/repos")
    end
  end

  def toggle_repo(conn, %{"encoded_name" => encoded}) do
    full_name = URI.decode_www_form(encoded)
    repo = Guild.Repo.get!(Guild.Schema.Repo, full_name)
    changeset = Ecto.Changeset.change(repo, enabled: !repo.enabled)
    Guild.Repo.update!(changeset)
    redirect(conn, to: ~p"/admin/repos")
  end

  def disable_repo(conn, %{"encoded_name" => encoded}) do
    full_name = URI.decode_www_form(encoded)
    repo = Guild.Repo.get!(Guild.Schema.Repo, full_name)
    changeset = Ecto.Changeset.change(repo, enabled: false)
    Guild.Repo.update!(changeset)
    redirect(conn, to: ~p"/admin/repos")
  end

  def workers(conn, _params) do
    workers = Guild.Repo.all(Guild.Schema.Worker)
    changeset = Guild.Schema.Worker.changeset(%Guild.Schema.Worker{}, %{})
    render(conn, :workers, workers: workers, changeset: changeset)
  end

  def create_worker(conn, params) do
    attrs = %{
      worker_id: String.trim(params["worker_id"] || ""),
      fountain_agent_id: String.trim(params["fountain_agent_id"] || ""),
      vault_id: String.trim(params["vault_id"] || ""),
      github_installation_id: case String.trim(params["github_installation_id"] || "") do
        "" -> nil
        v -> v
      end
    }

    changeset =
      Guild.Schema.Worker.changeset(%Guild.Schema.Worker{}, attrs)
      |> Map.put(:action, :insert)

    case Guild.Repo.insert(changeset) do
      {:ok, _worker} ->
        redirect(conn, to: ~p"/admin/workers")

      {:error, changeset} ->
        workers = Guild.Repo.all(Guild.Schema.Worker)
        conn
        |> put_status(200)
        |> render(:workers, workers: workers, changeset: changeset)
    end
  end

  def slack_channels(conn, _params) do
    channels = Guild.Repo.all(Guild.Schema.SlackChannel)
    repos = Guild.Repo.all(Guild.Schema.Repo)
    changeset = Ecto.Changeset.change(%Guild.Schema.SlackChannel{})
    render(conn, :slack_channels, channels: channels, repos: repos, changeset: changeset)
  end

  def create_slack_channel(conn, params) do
    channel_id = String.trim(params["channel_id"] || "")
    default_repo = case String.trim(params["default_repo"] || "") do
      "" -> nil
      v  -> v
    end

    if channel_id == "" do
      channels = Guild.Repo.all(Guild.Schema.SlackChannel)
      repos = Guild.Repo.all(Guild.Schema.Repo)
      changeset =
        Guild.Schema.SlackChannel.changeset(%Guild.Schema.SlackChannel{}, %{channel_id: ""})
        |> Ecto.Changeset.add_error(:channel_id, "can't be blank")
        |> Map.put(:action, :insert)
      conn
      |> put_status(200)
      |> render(:slack_channels, channels: channels, repos: repos, changeset: changeset)
    else
      attrs = %{
        channel_id: channel_id,
        default_repo: default_repo,
        enabled: true,
        notes: String.trim(params["notes"] || "")
      }
      changeset = Guild.Schema.SlackChannel.changeset(%Guild.Schema.SlackChannel{}, attrs)
      Guild.Repo.insert(changeset, on_conflict: :nothing, conflict_target: :channel_id)
      redirect(conn, to: ~p"/admin/slack-channels")
    end
  end

  def toggle_slack_channel(conn, %{"channel_id" => channel_id}) do
    channel = Guild.Repo.get!(Guild.Schema.SlackChannel, channel_id)
    changeset = Ecto.Changeset.change(channel, enabled: !channel.enabled)
    Guild.Repo.update!(changeset)
    redirect(conn, to: ~p"/admin/slack-channels")
  end

  def delete_slack_channel(conn, %{"channel_id" => channel_id}) do
    channel = Guild.Repo.get!(Guild.Schema.SlackChannel, channel_id)
    Guild.Repo.delete!(channel)
    redirect(conn, to: ~p"/admin/slack-channels")
  end

  def integrations(conn, _params) do
    github = github_status()
    slack = slack_status()
    linear = linear_status()
    fountain = fountain_status()
    openrouter = openrouter_status()

    render(conn, :integrations,
      github: github,
      slack: slack,
      linear: linear,
      fountain: fountain,
      openrouter: openrouter
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

  defp openrouter_status do
    api_key = Application.get_env(:guild, :openrouter_api_key)
    model = Application.get_env(:guild, :openrouter_classifier_model, "openai/gpt-4o-mini")
    status = if present?(api_key), do: :ready, else: :unconfigured

    {status, %{api_key_set: present?(api_key), model: model}}
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
