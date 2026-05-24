defmodule Guild.Reconcile do
  use GenServer
  require Logger
  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.Schema.Event
  alias Guild.Schema.Artifact
  alias Guild.Primitives.Meta

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

  def handle_info(:reconcile, state) do
    do_reconcile()
    {:noreply, state}
  end

  defp do_reconcile do
    pass_a()
    pass_b()
  end

  # Pass A: executing → pr_open
  defp pass_a do
    threads =
      Repo.all(
        from t in Thread,
          join: a in Artifact,
          on: a.thread_id == t.id and a.artifact_type == "fountain_conversation",
          where: t.state == "executing",
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

  defp reconcile_executing_thread(thread, artifact) do
    conv_id = artifact.external_id

    case Guild.Adapters.Fountain.get_status(conv_id) do
      {:ok, :idle} ->
        check_for_pr(thread)

      {:ok, status} ->
        Logger.debug("Thread #{thread.id}: Fountain status #{status}, skipping")

      {:error, tier, reason} ->
        Logger.warning(
          "Thread #{thread.id}: Fountain get_status error (#{tier}): #{inspect(reason)}"
        )
    end
  end

  defp check_for_pr(thread) do
    repo = extract_repo_from_thread(thread)

    if is_nil(repo) do
      Logger.warning("Thread #{thread.id}: could not determine repo, skipping PR check")
    else
      issue_number = thread.anchor_id

      case Guild.GitHub.impl().list_pull_requests(repo, state: "open") do
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

    %Artifact{}
    |> Artifact.changeset(%{
      thread_id: thread.id,
      artifact_type: "pull_request",
      source: "github",
      external_id: pr_number,
      url: pr_url
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :external_id])

    case Meta.update_thread_state(thread.id, :pr_opened) do
      {:ok, :pr_open} ->
        Logger.info("Thread #{thread.id} transitioned executing → pr_open (PR ##{pr_number})")

      {:error, tier, reason} ->
        Logger.warning(
          "Thread #{thread.id}: state transition error (#{tier}): #{inspect(reason)}"
        )
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

        {:error, tier, reason} ->
          Logger.warning(
            "Thread #{thread.id}: state transition error (#{tier}): #{inspect(reason)}"
          )
      end
    end
  end
end
