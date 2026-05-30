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
  # Helpers
  # ---------------------------------------------------------------------------

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, val), do: Application.put_env(app, key, val)
end
