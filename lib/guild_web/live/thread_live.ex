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
    timeline = build_timeline(thread)

    {:ok,
     assign(socket,
       thread: thread,
       fountain_base_url: fountain_base_url,
       stuck?: stuck?(thread),
       conv_status: conv_status,
       timeline: timeline
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    thread = load_thread(socket.assigns.thread.id)
    conv_status = fetch_conv_status(thread)
    timeline = build_timeline(thread)
    {:noreply, assign(socket, thread: thread, stuck?: stuck?(thread), conv_status: conv_status, timeline: timeline)}
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

  defp build_timeline(thread) do
    events =
      Enum.map(thread.events, fn e ->
        actor =
          cond do
            e.actor_type && e.actor_id -> "#{e.actor_type}/#{e.actor_id}"
            e.actor_type -> e.actor_type
            e.actor_id -> e.actor_id
            true -> nil
          end

        %{
          timestamp: e.occurred_at,
          kind: "event",
          summary: "#{e.event_type} (#{e.source})",
          meta: %{actor: actor}
        }
      end)

    notes =
      Enum.map(thread.context_notes, fn n ->
        body = n.body || ""
        display = String.slice(body, 0, 120) <> if String.length(body) > 120, do: "…", else: ""

        %{
          timestamp: n.inserted_at,
          kind: "note",
          summary: "#{n.note_type}: #{display}",
          meta: %{}
        }
      end)

    decisions =
      Enum.map(thread.decisions_log, fn d ->
        reasoning = d.reasoning || ""
        display = String.slice(reasoning, 0, 120) <> if String.length(reasoning) > 120, do: "…", else: ""

        %{
          timestamp: d.inserted_at,
          kind: "decision",
          summary: "#{d.decision_type}: #{display}",
          meta: %{has_snapshot: not is_nil(d.context_snapshot)}
        }
      end)

    artifacts =
      Enum.map(thread.artifacts, fn a ->
        %{
          timestamp: a.inserted_at,
          kind: "artifact",
          summary: "#{a.artifact_type} from #{a.source}",
          meta: %{url: a.url, external_id: a.external_id}
        }
      end)

    (events ++ notes ++ decisions ++ artifacts)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
  end
end
