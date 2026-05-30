defmodule Guild.Digest do
  @moduledoc """
  Daily operator digest: posts a summary of thread counts and stuck threads to Slack.

  Scheduled as an Oban Cron job at 09:00 UTC daily.
  """

  use Oban.Worker, queue: :claims

  require Logger
  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Thread

  # How old a thread must be (without state change) to be considered "stuck".
  @stuck_threshold_hours 48
  @stuck_threshold_seconds @stuck_threshold_hours * 3600

  @cron_schedule "0 9 * * *"

  @doc """
  Returns the cron schedule expression for this digest job.
  """
  def cron_schedule, do: @cron_schedule

  @impl Oban.Worker
  def perform(_job) do
    send_digest()
    :ok
  end

  @doc """
  Query thread counts, format a Slack message, and post it.
  No-op (returns :ok) if Slack is not configured.
  """
  def send_digest do
    now = DateTime.utc_now()
    stuck_cutoff = DateTime.add(now, -@stuck_threshold_seconds, :second)

    # Count threads by state
    state_counts =
      Repo.all(
        from t in Thread,
          group_by: t.state,
          select: {t.state, count(t.id)}
      )
      |> Map.new()

    done_count = Map.get(state_counts, "done", 0)
    executing_count = Map.get(state_counts, "executing", 0)
    pr_open_count = Map.get(state_counts, "pr_open", 0)
    held_count = Repo.aggregate(from(t in Thread, where: t.held == true), :count)

    # Stuck: not held, in executing or pr_open, state entered (or last updated) before cutoff
    stuck_threads =
      Repo.all(
        from t in Thread,
          where: t.state in ["executing", "pr_open"],
          where: t.held == false,
          where: coalesce(t.state_entered_at, t.updated_at) < ^stuck_cutoff,
          order_by: [asc: coalesce(t.state_entered_at, t.updated_at)],
          limit: 3
      )

    stuck_count =
      Repo.aggregate(
        from(t in Thread,
          where: t.state in ["executing", "pr_open"],
          where: t.held == false,
          where: coalesce(t.state_entered_at, t.updated_at) < ^stuck_cutoff
        ),
        :count
      )

    in_flight_count = executing_count + pr_open_count

    worst_stuck_lines =
      Enum.map(stuck_threads, fn thread ->
        reference_time = thread.state_entered_at || thread.updated_at
        age_hours = div(DateTime.diff(now, reference_time, :second), 3600)
        "• ##{thread.anchor_id} (#{thread.state}, #{age_hours}h old)"
      end)

    text = build_digest_text(done_count, in_flight_count, stuck_count, held_count, worst_stuck_lines)

    case Guild.Adapters.Slack.post_message(text) do
      {:ok, _} -> :ok
      {:error, tier, reason} ->
        Logger.warning("Guild.Digest: failed to post digest (#{tier}): #{inspect(reason)}")
        :ok
    end
  end

  defp build_digest_text(done_count, in_flight_count, stuck_count, held_count, worst_stuck_lines) do
    lines = [
      "*Daily Guild Digest*",
      ":white_check_mark: Shipped (done): #{done_count}",
      ":rocket: In-flight (executing + pr_open): #{in_flight_count}",
      ":warning: Stuck (>#{@stuck_threshold_hours}h, not held): #{stuck_count}",
      ":pause_button: Held: #{held_count}"
    ]

    lines =
      if worst_stuck_lines != [] do
        lines ++ ["", "*Worst stuck threads:*"] ++ worst_stuck_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end
end
