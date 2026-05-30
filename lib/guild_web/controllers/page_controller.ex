defmodule GuildWeb.PageController do
  use GuildWeb, :controller

  def home(conn, _params) do
    gaps = Guild.Setup.gaps()
    render(conn, :home, gaps: gaps)
  end
end
