defmodule GuildWeb.ThreadController do
  use GuildWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    threads = Guild.Repo.all(from t in Guild.Schema.Thread, order_by: [desc: t.updated_at])
    render(conn, :index, threads: threads)
  end
end
