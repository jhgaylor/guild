defmodule GuildWeb.Router do
  use GuildWeb, :router
  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GuildWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug :operator_auth
  end

  scope "/api", GuildWeb do
    pipe_through :api

    post "/webhooks/github", WebhookController, :receive
  end

  # Alias for the GitHub App webhook URL configured WITHOUT the /api prefix.
  # The canonical path is /api/webhooks/github; this alias makes the App webhook
  # work whether the App settings point at /webhooks/github or /api/webhooks/github.
  scope "/", GuildWeb do
    pipe_through :api

    post "/webhooks/github", WebhookController, :receive
  end

  # Slack slash commands, interactions, and events — auth via Slack v0 HMAC signature, NOT the :auth pipeline.
  scope "/slack", GuildWeb do
    post "/commands", SlackController, :commands
    post "/interactions", SlackController, :interactions
    post "/events", SlackController, :events
  end

  # Linear webhooks — auth via HMAC-SHA256 signature, NOT the :auth pipeline.
  scope "/linear", GuildWeb do
    post "/webhooks", LinearController, :webhooks
  end

  scope "/", GuildWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", GuildWeb do
    pipe_through [:browser, :auth]

    get "/threads", ThreadController, :index
    get "/decisions", DecisionController, :index

    oban_dashboard "/jobs"

    live_session :authenticated, on_mount: {GuildWeb.OperatorAuth, :require_auth} do
      live "/threads/:id", ThreadLive, :show
    end

    post "/threads/:id/hold", ThreadActionController, :hold
    post "/threads/:id/resume", ThreadActionController, :resume
    post "/threads/:id/abandon", ThreadActionController, :abandon

    scope "/admin" do
      get "/", AdminController, :index
      get "/repos", AdminController, :repos
      post "/repos", AdminController, :create_repo
      patch "/repos/:encoded_name/toggle", AdminController, :toggle_repo
      delete "/repos/:encoded_name", AdminController, :disable_repo
      get "/workers", AdminController, :workers
      post "/workers", AdminController, :create_worker
      get "/integrations", AdminController, :integrations
      get "/slack-channels", AdminController, :slack_channels
      post "/slack-channels", AdminController, :create_slack_channel
      patch "/slack-channels/:channel_id/toggle", AdminController, :toggle_slack_channel
      delete "/slack-channels/:channel_id", AdminController, :delete_slack_channel
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", GuildWeb do
  #   pipe_through :api
  # end

  defp operator_auth(conn, _opts) do
    conn =
      Plug.BasicAuth.basic_auth(conn,
        username: System.fetch_env!("OPERATOR_USERNAME"),
        password: System.fetch_env!("OPERATOR_PASSWORD")
      )

    if conn.halted do
      conn
    else
      Plug.Conn.put_session(conn, :authenticated, true)
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:guild, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: GuildWeb.Telemetry
    end
  end
end
