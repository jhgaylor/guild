defmodule Guild.E2E.ContributeMdTest do
  use Guild.DataCase
  @moduletag :e2e

  @repo "jhgaylor/guild"
  @issue_number 3
  @timeout_ms 30 * 60 * 1_000

  test "worker claims issue #3, writes CONTRIBUTING.md, opens PR" do
    # Step 1: ClaimSeed — creates thread, claims issue #3
    Mix.Tasks.Guild.ClaimSeed.run([
      "--repo",
      @repo,
      "--issue-number",
      to_string(@issue_number)
    ])

    thread =
      Guild.Repo.get_by!(Guild.Schema.Thread,
        anchor_type: "github_issue",
        anchor_id: to_string(@issue_number)
      )

    assert thread.state == "claimed"

    # Step 2: Dispatch Fountain conversation
    agent_id = Application.get_env(:guild, :guild_implementer_agent_id)

    prompt = """
    You have been assigned to implement GitHub issue ##{@issue_number} in #{@repo}.
    Read the issue body for acceptance criteria, implement the fix, run mix test, and open a PR.
    """

    {:ok, %{id: conv_id}} =
      Guild.Adapters.Fountain.dispatch_conversation(agent_id, nil, prompt)

    # Record the conversation as an artifact
    Guild.Repo.insert!(%Guild.Schema.Artifact{
      thread_id: thread.id,
      artifact_type: "fountain_conversation",
      source: "fountain",
      external_id: conv_id,
      url:
        "#{Application.get_env(:guild, :fountain_base_url)}/conversations/#{conv_id}"
    })

    # Step 3: Poll until the Fountain conversation reaches :idle
    assert_eventually(
      fn ->
        case Guild.Adapters.Fountain.get_status(conv_id) do
          {:ok, :idle} -> true
          _ -> false
        end
      end,
      timeout: @timeout_ms,
      interval: 15_000
    )

    # Step 4: Assert a pull_request artifact was written
    pr_artifact =
      Guild.Repo.get_by(Guild.Schema.Artifact,
        thread_id: thread.id,
        artifact_type: "pull_request"
      )

    assert pr_artifact != nil, "Expected a pull_request artifact on the thread"
    assert String.contains?(pr_artifact.url, "github.com"), "Expected a GitHub PR URL"

    # Step 5: Assert thread transitioned to pr_open
    thread = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
    assert thread.state == "pr_open"
  end

  defp assert_eventually(fun, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    interval = Keyword.get(opts, :interval, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline, interval)
  end

  defp do_assert_eventually(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("Timed out waiting for condition after #{div(@timeout_ms, 60_000)} minutes")
      end

      Process.sleep(interval)
      do_assert_eventually(fun, deadline, interval)
    end
  end
end
