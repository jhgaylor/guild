defmodule GuildWeb.PageController do
  use GuildWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
