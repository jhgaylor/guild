defmodule GuildWeb.AdminControllerTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  # ---------------------------------------------------------------------------
  # Home page tests
  # ---------------------------------------------------------------------------

  describe "GET /" do
    test "returns 200 with hero copy", %{conn: conn} do
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      assert body =~ "watches your repos"
    end

    test "contains Try it on your repo link", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Try it on your repo"
    end

    test "contains link to /threads", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ ~p"/threads"
    end

    test "contains link to /jobs", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ ~p"/jobs"
    end

    test "contains link to /admin", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ ~p"/admin"
    end
  end

  # ---------------------------------------------------------------------------
  # /admin shell tests
  # ---------------------------------------------------------------------------

  describe "GET /admin" do
    test "without auth returns 401", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      assert conn.status == 401
    end

    test "with valid basic auth returns 200", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin")
      assert html_response(conn, 200) =~ "Admin"
    end

    test "with auth contains link to /admin/repos", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin")
      assert html_response(conn, 200) =~ ~p"/admin/repos"
    end

    test "with auth contains link to /admin/workers", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin")
      assert html_response(conn, 200) =~ ~p"/admin/workers"
    end

    test "with auth contains link to /admin/integrations", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin")
      assert html_response(conn, 200) =~ ~p"/admin/integrations"
    end
  end

  # ---------------------------------------------------------------------------
  # /admin/integrations tests
  # ---------------------------------------------------------------------------

  describe "GET /admin/integrations" do
    test "with auth returns 200 and renders all four cards", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "GitHub App"
      assert body =~ "Slack"
      assert body =~ "Linear"
      assert body =~ "Fountain"
      assert body =~ "OpenRouter"
    end

    test "renders OpenRouter card", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      assert html_response(conn, 200) =~ "OpenRouter"
    end

    test "GitHub card shows ready when all env vars set", %{conn: conn} do
      Application.put_env(:guild, :github_webhook_secret, "test-secret")

      on_exit(fn ->
        Application.delete_env(:guild, :github_webhook_secret)
      end)

      orig_app_id = System.get_env("GITHUB_APP_ID")
      orig_key = System.get_env("GITHUB_PRIVATE_KEY")
      orig_install = System.get_env("GITHUB_INSTALLATION_ID")

      System.put_env("GITHUB_APP_ID", "12345")
      System.put_env("GITHUB_PRIVATE_KEY", "test-key")
      System.put_env("GITHUB_INSTALLATION_ID", "67890")

      on_exit(fn ->
        restore_env("GITHUB_APP_ID", orig_app_id)
        restore_env("GITHUB_PRIVATE_KEY", orig_key)
        restore_env("GITHUB_INSTALLATION_ID", orig_install)
      end)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "ready"
    end

    test "GitHub card shows unconfigured when env vars absent", %{conn: conn} do
      orig_app_id = System.get_env("GITHUB_APP_ID")
      orig_key = System.get_env("GITHUB_PRIVATE_KEY")
      orig_install = System.get_env("GITHUB_INSTALLATION_ID")

      System.delete_env("GITHUB_APP_ID")
      System.delete_env("GITHUB_PRIVATE_KEY")
      System.delete_env("GITHUB_INSTALLATION_ID")

      on_exit(fn ->
        restore_env("GITHUB_APP_ID", orig_app_id)
        restore_env("GITHUB_PRIVATE_KEY", orig_key)
        restore_env("GITHUB_INSTALLATION_ID", orig_install)
      end)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "unconfigured"
    end

    test "Slack card shows ready when all keys set", %{conn: conn} do
      Application.put_env(:guild, :slack_signing_secret, "signing-secret")
      Application.put_env(:guild, :slack_bot_token, "xoxb-test-token")
      Application.put_env(:guild, :slack_channel_id, "C12345")

      on_exit(fn ->
        Application.delete_env(:guild, :slack_signing_secret)
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
      end)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "ready"
    end

    test "Slack card shows unconfigured when keys absent", %{conn: conn} do
      Application.delete_env(:guild, :slack_signing_secret)
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "unconfigured"
    end

    test "Linear card shows ready when api_key and team_id set", %{conn: conn} do
      Application.put_env(:guild, :linear_api_key, "lin_api_test")
      Application.put_env(:guild, :linear_team_id, "team-abc")

      on_exit(fn ->
        Application.delete_env(:guild, :linear_api_key)
        Application.delete_env(:guild, :linear_team_id)
      end)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "ready"
    end

    test "Linear card shows unconfigured when keys absent", %{conn: conn} do
      Application.delete_env(:guild, :linear_api_key)
      Application.delete_env(:guild, :linear_team_id)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "unconfigured"
    end

    test "Fountain card shows unconfigured when keys absent", %{conn: conn} do
      orig_api_key = Application.get_env(:guild, :fountain_api_key)
      orig_base_url = Application.get_env(:guild, :fountain_base_url)
      orig_agent_id = Application.get_env(:guild, :guild_implementer_agent_id)

      Application.delete_env(:guild, :fountain_api_key)
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :guild_implementer_agent_id)

      on_exit(fn ->
        restore_app_env(:guild, :fountain_api_key, orig_api_key)
        restore_app_env(:guild, :fountain_base_url, orig_base_url)
        restore_app_env(:guild, :guild_implementer_agent_id, orig_agent_id)
      end)

      conn = conn |> with_auth() |> get(~p"/admin/integrations")
      body = html_response(conn, 200)
      assert body =~ "unconfigured"
    end
  end

  # ---------------------------------------------------------------------------
  # /admin/slack-channels tests
  # ---------------------------------------------------------------------------

  describe "GET /admin/slack-channels" do
    test "without auth returns 401", %{conn: conn} do
      conn = get(conn, ~p"/admin/slack-channels")
      assert conn.status == 401
    end

    test "with auth returns 200", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/slack-channels")
      assert html_response(conn, 200) =~ "Slack Channels"
    end

    test "lists existing channels", %{conn: conn} do
      {:ok, _} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C111TEST"})
      conn = conn |> with_auth() |> get(~p"/admin/slack-channels")
      assert html_response(conn, 200) =~ "C111TEST"
    end
  end

  describe "POST /admin/slack-channels" do
    # The form on /admin/slack-channels uses <.form for={@changeset}>, which
    # posts schema fields nested under "slack_channel[...]". The raw
    # "default_repo" <select> stays at the top level. Tests post the real shape.

    test "creates a channel and redirects", %{conn: conn} do
      conn =
        conn
        |> with_auth()
        |> post(~p"/admin/slack-channels", %{
          "slack_channel" => %{"channel_id" => "C222TEST", "notes" => ""},
          "default_repo" => ""
        })
      assert redirected_to(conn) == ~p"/admin/slack-channels"
      assert Guild.Repo.get(Guild.Schema.SlackChannel, "C222TEST") != nil
    end

    test "stores notes and default_repo when provided", %{conn: conn} do
      {:ok, _} = Guild.Repo.insert(%Guild.Schema.Repo{full_name: "owner/repo", worker_id: "default", enabled: true})

      conn =
        conn
        |> with_auth()
        |> post(~p"/admin/slack-channels", %{
          "slack_channel" => %{"channel_id" => "C555NOTES", "notes" => "ops triage"},
          "default_repo" => "owner/repo"
        })

      assert redirected_to(conn) == ~p"/admin/slack-channels"
      ch = Guild.Repo.get!(Guild.Schema.SlackChannel, "C555NOTES")
      assert ch.notes == "ops triage"
      assert ch.default_repo == "owner/repo"
      assert ch.enabled == true
    end

    test "blank channel_id renders single error and persists nothing", %{conn: conn} do
      conn =
        conn
        |> with_auth()
        |> post(~p"/admin/slack-channels", %{
          "slack_channel" => %{"channel_id" => "", "notes" => ""},
          "default_repo" => ""
        })

      body = html_response(conn, 200)
      assert body =~ "Slack Channels"
      # Exactly one "can't be blank" message — regression guard for earlier
      # impl that added the error twice (validate_required + explicit add_error).
      assert length(Regex.scan(~r/can&#39;t be blank|can't be blank/, body)) == 1
      assert Guild.Repo.aggregate(Guild.Schema.SlackChannel, :count) == 0
    end
  end

  describe "PATCH /admin/slack-channels/:channel_id/toggle" do
    test "toggles enabled flag", %{conn: conn} do
      {:ok, ch} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C333TEST", enabled: true})
      conn =
        conn
        |> with_auth()
        |> patch(~p"/admin/slack-channels/#{ch.channel_id}/toggle")
      assert redirected_to(conn) == ~p"/admin/slack-channels"
      updated = Guild.Repo.get!(Guild.Schema.SlackChannel, "C333TEST")
      assert updated.enabled == false
    end
  end

  describe "DELETE /admin/slack-channels/:channel_id" do
    test "removes the channel", %{conn: conn} do
      {:ok, ch} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C444TEST"})
      conn =
        conn
        |> with_auth()
        |> delete(~p"/admin/slack-channels/#{ch.channel_id}")
      assert redirected_to(conn) == ~p"/admin/slack-channels"
      assert Guild.Repo.get(Guild.Schema.SlackChannel, "C444TEST") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # /admin/slack-inbox tests
  # ---------------------------------------------------------------------------

  describe "GET /admin/slack-inbox" do
    test "without auth returns 401", %{conn: conn} do
      conn = get(conn, ~p"/admin/slack-inbox")
      assert conn.status == 401
    end

    test "with auth returns 200", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/slack-inbox")
      assert html_response(conn, 200) =~ "Slack Inbox"
    end

    test "lists existing inbox events", %{conn: conn} do
      {:ok, _} = Guild.Repo.insert(
        Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
          event_id: "evt_admin_test",
          channel_id: "C_ADMIN",
          user_id: "U_ADMIN",
          message_ts: "111.222",
          message_text: "fix the login bug please",
          verdict: "new_work",
          confidence: 0.92,
          reasoning: "direct task request",
          action_taken: "dry_run"
        })
      )
      conn = conn |> with_auth() |> get(~p"/admin/slack-inbox")
      body = html_response(conn, 200)
      assert body =~ "C_ADMIN"
      assert body =~ "fix the login bug"
    end
  end

  describe "POST /admin/slack-inbox/:id/reclassify — mark noise" do
    test "sets override_verdict to noise and redirects", %{conn: conn} do
      {:ok, event} = Guild.Repo.insert(
        Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
          event_id: "evt_reclassify_noise",
          channel_id: "C_RECLASSIFY",
          user_id: "U123",
          message_ts: "111.333",
          message_text: "good morning everyone",
          verdict: "new_work",
          confidence: 0.75,
          reasoning: "seemed like a task",
          action_taken: "dry_run"
        })
      )

      conn =
        conn
        |> with_auth()
        |> post(~p"/admin/slack-inbox/#{event.id}/reclassify", %{"verdict" => "noise"})

      assert redirected_to(conn) == ~p"/admin/slack-inbox"

      updated = Guild.Repo.get!(Guild.Schema.SlackInboxEvent, event.id)
      assert updated.override_verdict == "noise"
    end
  end

  describe "POST /admin/slack-inbox/:id/reclassify — file as new work" do
    test "creates GitHub issue and sets override_verdict to new_work", %{conn: conn} do
      {:ok, _channel} = Guild.Repo.insert(
        Guild.Schema.SlackChannel.changeset(%Guild.Schema.SlackChannel{}, %{
          channel_id: "C_NW",
          default_repo: "owner/repo",
          enabled: true
        })
      )

      {:ok, event} = Guild.Repo.insert(
        Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
          event_id: "evt_reclassify_nw",
          channel_id: "C_NW",
          user_id: "U_NW",
          message_ts: "111.444",
          message_text: "fix the payment bug",
          verdict: "noise",
          confidence: 0.4,
          reasoning: "misclassified",
          action_taken: "dry_run"
        })
      )

      Guild.GitHub.TestAdapter.configure(:create_issue, {:ok, %{"html_url" => "https://github.com/owner/repo/issues/42"}})

      conn =
        conn
        |> with_auth()
        |> post(~p"/admin/slack-inbox/#{event.id}/reclassify", %{"verdict" => "new_work"})

      assert redirected_to(conn) == ~p"/admin/slack-inbox"

      updated = Guild.Repo.get!(Guild.Schema.SlackInboxEvent, event.id)
      assert updated.override_verdict == "new_work"
      assert updated.action_taken == "issue_created"
      assert updated.github_issue_url == "https://github.com/owner/repo/issues/42"
    end
  end

  # ---------------------------------------------------------------------------
  # /admin/repos tests
  # ---------------------------------------------------------------------------

  describe "GET /admin/repos" do
    test "with auth returns 200", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/repos")
      assert html_response(conn, 200) =~ "Repos"
    end

    test "with auth renders seeded repo in table", %{conn: conn} do
      Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/testrepo", worker_id: "default", enabled: true})
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)

      conn = conn |> with_auth() |> get(~p"/admin/repos")
      assert html_response(conn, 200) =~ "owner/testrepo"
    end
  end

  describe "POST /admin/repos" do
    setup do
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
      :ok
    end

    test "with valid full_name creates repo and redirects", %{conn: conn} do
      conn = conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
      assert redirected_to(conn) == ~p"/admin/repos"
      assert Guild.Repo.get(Guild.Schema.Repo, "owner/testrepo") != nil
    end

    test "second POST with same full_name is a no-op (idempotent)", %{conn: conn} do
      conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
      conn2 = build_conn() |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
      assert redirected_to(conn2) == ~p"/admin/repos"
      assert Guild.Repo.aggregate(Guild.Schema.Repo, :count, :full_name) == 1
    end

    test "with blank full_name returns 200 with error and no row created", %{conn: conn} do
      conn = conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "", worker_id: "default"})
      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
      assert Guild.Repo.aggregate(Guild.Schema.Repo, :count, :full_name) == 0
    end
  end

  describe "PATCH /admin/repos/:encoded_name/toggle" do
    setup do
      Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/togglerepo", worker_id: "default", enabled: true})
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
      :ok
    end

    test "flips enabled from true to false", %{conn: conn} do
      encoded = URI.encode_www_form("owner/togglerepo")
      conn = conn |> with_auth() |> patch(~p"/admin/repos/#{encoded}/toggle")
      assert redirected_to(conn) == ~p"/admin/repos"
      repo = Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo")
      assert repo.enabled == false
    end

    test "flips enabled from false to true", %{conn: conn} do
      Guild.Repo.update!(Ecto.Changeset.change(Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo"), enabled: false))
      encoded = URI.encode_www_form("owner/togglerepo")
      conn = conn |> with_auth() |> patch(~p"/admin/repos/#{encoded}/toggle")
      assert redirected_to(conn) == ~p"/admin/repos"
      repo = Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo")
      assert repo.enabled == true
    end
  end

  describe "DELETE /admin/repos/:encoded_name" do
    setup do
      Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/deleterepo", worker_id: "default", enabled: true})
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
      :ok
    end

    test "sets enabled: false without hard-deleting the row", %{conn: conn} do
      encoded = URI.encode_www_form("owner/deleterepo")
      conn = conn |> with_auth() |> delete(~p"/admin/repos/#{encoded}")
      assert redirected_to(conn) == ~p"/admin/repos"
      repo = Guild.Repo.get(Guild.Schema.Repo, "owner/deleterepo")
      assert repo != nil
      assert repo.enabled == false
    end
  end

  # ---------------------------------------------------------------------------
  # /admin/workers tests
  # ---------------------------------------------------------------------------

  describe "GET /admin/workers" do
    test "with auth returns 200 and renders workers table", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/admin/workers")
      body = html_response(conn, 200)
      assert body =~ "Workers"
    end

    test "with auth renders seeded worker in table", %{conn: conn} do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-uuid",
        vault_id: "vault-uuid"
      })
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Worker) end)

      conn = conn |> with_auth() |> get(~p"/admin/workers")
      assert html_response(conn, 200) =~ "test-worker"
    end
  end

  describe "POST /admin/workers" do
    setup do
      on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Worker) end)
      :ok
    end

    test "with valid params creates worker and redirects", %{conn: conn} do
      conn = conn |> with_auth() |> post(~p"/admin/workers", %{
        worker_id: "new-worker",
        fountain_agent_id: "agent-abc",
        vault_id: "vault-abc"
      })
      assert redirected_to(conn) == ~p"/admin/workers"
      assert Guild.Repo.get(Guild.Schema.Worker, "new-worker") != nil
    end

    test "with missing worker_id returns 200 with error", %{conn: conn} do
      conn = conn |> with_auth() |> post(~p"/admin/workers", %{
        worker_id: "",
        fountain_agent_id: "agent-abc",
        vault_id: "vault-abc"
      })
      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
      assert Guild.Repo.aggregate(Guild.Schema.Worker, :count, :worker_id) == 0
    end

    test "with missing fountain_agent_id returns 200 with error", %{conn: conn} do
      conn = conn |> with_auth() |> post(~p"/admin/workers", %{
        worker_id: "new-worker",
        fountain_agent_id: "",
        vault_id: "vault-abc"
      })
      body = html_response(conn, 200)
      assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
    end
  end

  # ---------------------------------------------------------------------------
  # Banner tests
  # ---------------------------------------------------------------------------

  describe "GET / banner" do
    setup do
      on_exit(fn ->
        Guild.Repo.delete_all(Guild.Schema.Repo)
        Guild.Repo.delete_all(Guild.Schema.Worker)
      end)
      :ok
    end

    test "with zero repos shows no repos configured message", %{conn: conn} do
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      assert body =~ "No repos configured"
    end

    test "with one enabled repo, banner is absent for repos gap", %{conn: conn} do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "bw",
        fountain_agent_id: "agent",
        vault_id: "vault"
      })
      Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/r", worker_id: "bw", enabled: true})
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      refute body =~ "No repos configured"
    end
  end

  describe "GET /threads banner" do
    setup do
      on_exit(fn ->
        Guild.Repo.delete_all(Guild.Schema.Repo)
        Guild.Repo.delete_all(Guild.Schema.Worker)
      end)
      :ok
    end

    test "with zero repos shows no repos configured message", %{conn: conn} do
      conn = conn |> with_auth() |> get(~p"/threads")
      body = html_response(conn, 200)
      assert body =~ "No repos configured"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, val), do: Application.put_env(app, key, val)
end
