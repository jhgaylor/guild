defmodule Mix.Tasks.Guild.ClaimSeedTest do
  use Guild.DataCase, async: false

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Event
  alias Guild.Schema.Thread

  setup do
    Guild.GitHub.TestAdapter.reset()
    :ok
  end

  describe "run/1 happy path" do
    test "creates a claimed thread and seed event" do
      Mix.Tasks.Guild.ClaimSeed.run(["--repo", "owner/test", "--issue-number", "42"])

      threads =
        Repo.all(
          from t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "42"
        )

      assert length(threads) == 1
      thread = hd(threads)
      assert thread.anchor_type == "github_issue"
      assert thread.anchor_id == "42"
      assert thread.state == "claimed"

      events =
        Repo.all(
          from e in Event,
            where: e.idempotency_key == "seed:github_issue:42"
        )

      assert length(events) == 1
    end
  end

  describe "idempotency" do
    test "double-run produces exactly one thread row and one event row" do
      Mix.Tasks.Guild.ClaimSeed.run(["--repo", "owner/test", "--issue-number", "99"])
      Mix.Tasks.Guild.ClaimSeed.run(["--repo", "owner/test", "--issue-number", "99"])

      thread_count =
        Repo.aggregate(
          from(t in Thread,
            where: t.anchor_type == "github_issue" and t.anchor_id == "99"
          ),
          :count
        )

      assert thread_count == 1

      event_count =
        Repo.aggregate(
          from(e in Event, where: e.idempotency_key == "seed:github_issue:99"),
          :count
        )

      assert event_count == 1
    end
  end

  describe "missing arguments" do
    test "missing --repo exits 1" do
      assert catch_exit(
               Mix.Tasks.Guild.ClaimSeed.run(["--issue-number", "1"])
             ) == {:shutdown, 1}
    end

    test "missing --issue-number exits 1" do
      assert catch_exit(
               Mix.Tasks.Guild.ClaimSeed.run(["--repo", "owner/repo"])
             ) == {:shutdown, 1}
    end
  end
end
