defmodule GuildWeb.ThreadLive do
  use GuildWeb, :live_view
  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh)
    end

    thread = load_thread(id)
    fountain_base_url = Application.get_env(:guild, :fountain_base_url, "")
    {:ok, assign(socket, thread: thread, fountain_base_url: fountain_base_url, stuck?: stuck?(thread))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    thread = load_thread(socket.assigns.thread.id)
    {:noreply, assign(socket, thread: thread, stuck?: stuck?(thread))}
  end

  defp stuck?(thread) do
    age_s = DateTime.diff(DateTime.utc_now(), thread.updated_at)
    (thread.state == "executing" and age_s > 7_200) or
      (thread.state == "pr_open" and age_s > 172_800)
  end

  defp load_thread(id) do
    Guild.Schema.Thread
    |> Guild.Repo.get!(id)
    |> Guild.Repo.preload([
      :artifacts,
      :context_notes,
      :decisions_log,
      events: from(e in Guild.Schema.Event, order_by: [asc: e.occurred_at])
    ])
  end
end
