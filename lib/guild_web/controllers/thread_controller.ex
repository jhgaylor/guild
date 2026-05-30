defmodule GuildWeb.ThreadController do
  use GuildWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    threads = Guild.Repo.all(from t in Guild.Schema.Thread, order_by: [desc: t.updated_at])

    recent =
      Guild.Repo.all(
        from t in Guild.Schema.Thread,
          order_by: [desc: fragment("COALESCE(?, ?)", t.state_entered_at, t.updated_at)],
          limit: 5
      )

    render(conn, :index, threads: threads, recent: recent)
  end
end
