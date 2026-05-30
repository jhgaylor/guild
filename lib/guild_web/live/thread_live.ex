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
    conv_status = fetch_conv_status(thread)
    {:ok, assign(socket, thread: thread, fountain_base_url: fountain_base_url, stuck?: stuck?(thread), conv_status: conv_status)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    thread = load_thread(socket.assigns.thread.id)
    conv_status = fetch_conv_status(thread)
    {:noreply, assign(socket, thread: thread, stuck?: stuck?(thread), conv_status: conv_status)}
  end

  defp fetch_conv_status(thread) do
    artifact = Enum.find(thread.artifacts, fn a -> a.artifact_type == "fountain_conversation" end)

    if artifact do
      case Guild.Adapters.Fountain.get_status(artifact.external_id) do
        {:ok, status} -> status
        _ -> :unknown
      end
    else
      nil
    end
  end

  defp stuck?(thread) do
    reference_time = thread.state_entered_at || thread.updated_at
    age_s = DateTime.diff(DateTime.utc_now(), reference_time)
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
