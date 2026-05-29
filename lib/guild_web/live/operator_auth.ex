defmodule GuildWeb.OperatorAuth do
  @moduledoc """
  LiveView on_mount hook for operator authentication.

  The HTTP :auth pipeline validates BasicAuth credentials and stores
  `authenticated: true` in the session. This hook reads that session
  value to authorize the LiveView socket connection, ensuring WebSocket
  upgrades cannot bypass the HTTP-level BasicAuth check.
  """

  import Phoenix.LiveView

  def on_mount(:require_auth, _params, session, socket) do
    if Map.get(session, "authenticated") do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end
end
