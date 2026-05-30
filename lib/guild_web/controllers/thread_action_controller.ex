defmodule GuildWeb.ThreadActionController do
  use GuildWeb, :controller

  def hold(conn, %{"id" => id}) do
    Guild.Control.hold(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end

  def resume(conn, %{"id" => id}) do
    Guild.Control.resume(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end

  def abandon(conn, %{"id" => id}) do
    Guild.Control.abandon(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end
end
