defmodule Mix.Tasks.Guild.ClaimSeed do
  use Mix.Task

  @shortdoc "Seed a single GitHub issue as a claimed Guild thread"

  alias Guild.Primitives.Communication
  alias Guild.Primitives.Meta
  alias Guild.Primitives.WorkManagement
  alias Guild.Repo
  alias Guild.Schema.Event
  alias Guild.Schema.Thread

  import Ecto.Query, only: [from: 2]

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string, issue_number: :integer])
    repo = opts[:repo]
    issue_number = opts[:issue_number]

    unless repo && issue_number do
      Mix.shell().error("Usage: mix guild.claim_seed --repo owner/name --issue-number N")
      exit({:shutdown, 1})
    end

    Mix.Task.run("app.start")

    # Step 1: Fetch issue
    case github_adapter().get_issue(repo, issue_number) do
      {:ok, _issue} -> :ok
      {:error, _, reason} ->
        Mix.shell().error("Failed to fetch issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    # Step 2: Upsert thread
    Repo.insert(
      %Thread{
        anchor_type: "github_issue",
        anchor_id: to_string(issue_number),
        state: "unnoticed",
        owner: worker_identity()
      },
      on_conflict: :nothing,
      conflict_target: [:anchor_type, :anchor_id]
    )

    thread =
      Repo.one!(
        from t in Thread,
          where: t.anchor_type == "github_issue" and t.anchor_id == ^to_string(issue_number)
      )

    # Step 3: Transition unnoticed → noticed (skip if already past)
    thread =
      if thread.state == "unnoticed" do
        case Meta.update_thread_state(thread.id, :event_ingested) do
          {:ok, _} -> Repo.get!(Thread, thread.id)
          {:error, _, reason} ->
            Mix.shell().error("Failed to transition to noticed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
      else
        thread
      end

    # Step 4: Transition noticed → claimed (skip if already past)
    if thread.state == "noticed" do
      case Meta.update_thread_state(thread.id, :claim) do
        {:ok, _} -> :ok
        {:error, _, reason} ->
          Mix.shell().error("Failed to transition to claimed: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end

    # Step 5: Assign to self (best-effort). GitHub doesn't accept Apps as
    # issue assignees — the App identity (e.g. "guild-bot") returns 422
    # unless it's also a real user with repo read access. The thread
    # state and the "Taking this" comment carry the load-bearing signal;
    # the assignment is a nice-to-have presence cue. Log and continue.
    case WorkManagement.assign_to_self(repo, issue_number) do
      {:ok, _} -> :ok
      {:error, _, reason} ->
        Mix.shell().info("assign_to_self skipped: #{inspect(reason)}")
    end

    # Step 6: Comment on issue
    case Communication.comment_on_issue(
           repo,
           issue_number,
           "Taking this — will open a PR when ready."
         ) do
      {:ok, _} -> :ok
      {:error, _, reason} ->
        Mix.shell().error("Failed to comment on issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    # Step 7: Insert seed event (idempotent via idempotency_key)
    Repo.insert!(
      %Event{
        source: "guild",
        event_type: "seed_claimed",
        occurred_at: DateTime.utc_now(),
        thread_id: thread.id,
        idempotency_key: "seed:github_issue:#{issue_number}",
        raw_payload: %{"repo" => repo, "issue_number" => issue_number}
      },
      on_conflict: :nothing,
      conflict_target: [:idempotency_key]
    )

    Mix.shell().info("thread_id: #{thread.id}")
  end

  defp github_adapter, do: Application.get_env(:guild, :github_adapter, Guild.GitHub.TestAdapter)
  defp worker_identity, do: Application.get_env(:guild, :worker_identity, "guild-bot")
end
