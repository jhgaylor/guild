defmodule Guild.Reconcile do
  use GenServer
  require Logger
  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.Schema.Event
  alias Guild.Schema.Artifact
  alias Guild.Primitives.Meta

  @executing_stuck_after_ms 2 * 3_600_000
  @pr_open_stuck_after_ms 48 * 3_600_000
  @alert_cooldown_ms 6 * 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    :timer.send_interval(30_000, self(), :reconcile)
    {:ok, %{}}
  end

  # Public API - synchronous, callable directly (no GenServer overhead)
  def reconcile_all do
    do_reconcile()
    :ok
  end

  def reconcile_thread(thread_id) do
    thread = Repo.get(Thread, thread_id)

    if is_nil(thread) do
      Logger.debug("reconcile_thread/1: thread #{thread_id} not found")
    else
      try do
        case thread.state do
          "executing" ->
            artifact =
              Repo.one(
                from a in Artifact,
                  where: a.thread_id == ^thread.id and a.artifact_type == "fountain_conversation",
                  limit: 1
              )

            if artifact do
              reconcile_executing_thread(thread, artifact)
            else
              Logger.debug("Thread #{thread.id}: no fountain_conversation artifact")
            end

          "pr_open" ->
            artifact =
              Repo.one(
                from a in Artifact,
                  where: a.thread_id == ^thread.id and a.artifact_type == "pull_request",
                  limit: 1
              )

            if artifact do
              reconcile_pr_open_thread(thread, artifact)
            else
              Logger.debug("Thread #{thread.id}: no pull_request artifact")
            end

          state ->
            Logger.debug("Thread #{thread.id}: state #{state} does not require reconciliation")
        end
      rescue
        e ->
          Logger.warning("reconcile_thread/1 error for thread #{thread_id}: #{inspect(e)}")
      end
    end

    :ok
  end

  def handle_info(:reconcile, state) do
    do_reconcile()
    {:noreply, state}
  end

  defp do_reconcile do
    pass_a()
    pass_b()
    pass_c()
  end

  # Pass A: executing → pr_open
  defp pass_a do
    threads =
      Repo.all(
        from t in Thread,
          join: a in Artifact,
          on: a.thread_id == t.id and a.artifact_type == "fountain_conversation",
          where: t.state == "executing" and t.held == false,
          select: {t, a}
      )

    Enum.each(threads, fn {thread, artifact} ->
      try do
        reconcile_executing_thread(thread, artifact)
      rescue
        e ->
          Logger.warning("Reconcile pass A error for thread #{thread.id}: #{inspect(e)}")
      end
    end)
  end

  # A worker conversation stays alive after opening its PR (to handle review
  # feedback), so its Fountain status never reaches :idle on its own. Gating the
  # transition on conversation status therefore stalls the thread forever. The
  # existence of a matching PR is the real signal, so we check for it on every
  # tick regardless of conversation status.
  defp reconcile_executing_thread(thread, _artifact) do
    Guild.Summarization.maybe_summarize(thread.id)
    check_for_pr(thread)
  end

  defp check_for_pr(thread) do
    repo = extract_repo_from_thread(thread)

    if is_nil(repo) do
      Logger.warning("Thread #{thread.id}: could not determine repo, skipping PR check")
    else
      issue_number = thread.anchor_id

      # state: "all" so a PR that was opened and merged between reconcile ticks
      # is still matched (otherwise the thread stalls in executing forever).
      case Guild.GitHub.impl().list_pull_requests(repo, state: "all") do
        {:ok, prs} ->
          pattern = ~r/(Closes|Fixes) ##{Regex.escape(issue_number)}/i

          matching =
            Enum.find(prs, fn pr ->
              body = Map.get(pr, "body", "") || ""
              String.match?(body, pattern)
            end)

          if matching do
            promote_to_pr_open(thread, matching)
          end

        {:error, tier, reason} ->
          Logger.warning(
            "Thread #{thread.id}: GitHub list_pull_requests error (#{tier}): #{inspect(reason)}"
          )
      end
    end
  end

  defp extract_repo_from_thread(thread) do
    # Seed event idempotency_key: "claim_seed:{repo}:{issue_number}"
    # repo is "owner/name" (contains "/" but no ":")
    event =
      Repo.one(
        from e in Event,
          where: e.thread_id == ^thread.id,
          where: like(e.idempotency_key, "claim_seed:%"),
          limit: 1
      )

    if event do
      # "claim_seed:owner/repo:42" → ["claim_seed", "owner/repo", "42"]
      parts = String.split(event.idempotency_key, ":")
      Enum.at(parts, 1)
    else
      nil
    end
  end

  defp promote_to_pr_open(thread, pr) do
    pr_number = to_string(Map.get(pr, "number"))
    pr_url = Map.get(pr, "html_url", "")

    changeset =
      %Artifact{}
      |> Artifact.changeset(%{
        thread_id: thread.id,
        artifact_type: "pull_request",
        source: "github",
        external_id: pr_number,
        url: pr_url
      })

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:source, :external_id]) do
      {:ok, _artifact} ->
        case Meta.update_thread_state(thread.id, :pr_opened) do
          {:ok, :pr_open} ->
            Logger.info("Thread #{thread.id} transitioned executing → pr_open (PR ##{pr_number})")

            Guild.Adapters.Slack.post_message(
              "Thread ##{thread.id}: :pr_open — #{pr_url}"
            )

          {:error, tier, reason} ->
            Logger.warning(
              "Thread #{thread.id}: state transition error (#{tier}): #{inspect(reason)}"
            )
        end

      {:error, changeset} ->
        Logger.warning("Thread #{thread.id}: failed to insert pull_request artifact: #{inspect(changeset.errors)}")
    end
  end

  # Pass B: pr_open → done
  defp pass_b do
    threads =
      Repo.all(
        from t in Thread,
          join: a in Artifact,
          on: a.thread_id == t.id and a.artifact_type == "pull_request",
          where: t.state == "pr_open",
          select: {t, a}
      )

    Enum.each(threads, fn {thread, artifact} ->
      try do
        reconcile_pr_open_thread(thread, artifact)
      rescue
        e ->
          Logger.warning("Reconcile pass B error for thread #{thread.id}: #{inspect(e)}")
      end
    end)
  end

  defp reconcile_pr_open_thread(thread, artifact) do
    pr_number = artifact.external_id

    merged_event =
      Repo.one(
        from e in Event,
          where: e.thread_id == ^thread.id and e.event_type == "pull_request.merged",
          limit: 1
      )

    if merged_event do
      case Meta.update_thread_state(thread.id, :pr_merged) do
        {:ok, :done} ->
          Logger.info(
            "Thread #{thread.id} transitioned pr_open → done (PR ##{pr_number} merged)"
          )

          Guild.Adapters.Slack.post_message(
            "Thread ##{thread.id}: :done"
          )

          if thread.linear_issue_id do
            Guild.Adapters.Linear.update_issue(thread.linear_issue_id, %{
              stateId: Guild.Adapters.Linear.state_id(:done)
            })
          end

          Guild.Retention.trim_decisions_log(thread.id)

        {:error, tier, reason} ->
          Logger.warning(
            "Thread #{thread.id}: state transition error (#{tier}): #{inspect(reason)}"
          )
      end
    end
  end

  # Pass C: alert on stuck threads (executing too long or pr_open too long)
  defp pass_c do
    now = DateTime.utc_now()
    cooldown_cutoff = DateTime.add(now, -@alert_cooldown_ms, :millisecond)

    executing_cutoff = DateTime.add(now, -@executing_stuck_after_ms, :millisecond)
    pr_open_cutoff = DateTime.add(now, -@pr_open_stuck_after_ms, :millisecond)

    stuck_threads =
      Repo.all(
        from t in Thread,
          where:
            (t.state == "executing" and t.updated_at < ^executing_cutoff) or
              (t.state == "pr_open" and t.updated_at < ^pr_open_cutoff),
          where: is_nil(t.last_alerted_at) or t.last_alerted_at < ^cooldown_cutoff,
          where: t.held == false
      )

    Enum.each(stuck_threads, fn thread ->
      try do
        age_seconds = DateTime.diff(now, thread.updated_at)
        age_hours = div(age_seconds, 3600)

        Guild.Adapters.Slack.post_message(
          "Thread ##{thread.id} appears stuck: state=#{thread.state}, age=#{age_hours}h"
        )

        Repo.update!(Thread.changeset(thread, %{last_alerted_at: now}))
      rescue
        e ->
          Logger.warning("Reconcile pass C error for thread #{thread.id}: #{inspect(e)}")
      end
    end)
  end
end
