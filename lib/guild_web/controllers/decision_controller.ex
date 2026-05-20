defmodule GuildWeb.DecisionController do
  use GuildWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    decisions =
      Guild.Repo.all(
        from d in Guild.Schema.DecisionsLog,
          order_by: [desc: d.inserted_at],
          preload: :thread
      )

    render(conn, :index, decisions: decisions)
  end
end
