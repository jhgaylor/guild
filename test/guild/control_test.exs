defmodule Guild.ControlTest do
  use Guild.DataCase, async: false

  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.Control

  defp insert_thread(state, opts \\ []) do
    anchor_id = Keyword.get(opts, :anchor_id, to_string(System.unique_integer([:positive])))

    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: anchor_id,
        state: state,
        owner: Keyword.get(opts, :owner, nil)
      })
      |> Repo.insert()

    thread
  end

  describe "hold/1" do
    test "sets held = true on the thread (by issue number)" do
      thread = insert_thread("executing", anchor_id: "42")

      assert {:ok, _msg} = Control.hold("42")

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end

    test "sets held = true on the thread (by UUID)" do
      thread = insert_thread("executing")

      assert {:ok, _msg} = Control.hold(thread.id)

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end

    test "strips leading # from issue number" do
      thread = insert_thread("executing", anchor_id: "99")

      assert {:ok, _msg} = Control.hold("#99")

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end

    test "returns error when thread not found" do
      assert {:error, :not_found} = Control.hold("999999")
    end

    test "cancels available ClaimWorker Oban jobs for the thread" do
      _thread = insert_thread("executing", anchor_id: "55")

      # Insert an Oban job directly (bypass inline execution) in "available" state.
      Repo.insert!(%Oban.Job{
        worker: "Elixir.Guild.Workers.ClaimWorker",
        args: %{"repo" => "owner/repo", "issue_number" => 55, "worker_id" => "w1"},
        queue: "claims",
        state: "available",
        max_attempts: 3,
        inserted_at: DateTime.utc_now(),
        scheduled_at: DateTime.utc_now()
      })

      assert {:ok, _msg} = Control.hold("55")

      # Job should be in cancelled state after hold.
      job = Repo.one(from j in Oban.Job, where: j.worker == "Elixir.Guild.Workers.ClaimWorker")
      assert job.state == "cancelled"
    end
  end

  describe "resume/1" do
    test "sets held = false on a held thread" do
      thread = insert_thread("executing")
      # Manually set to held first
      Repo.update!(Thread.changeset(thread, %{held: true}))

      assert {:ok, _msg} = Control.resume(thread.id)

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == false
    end

    test "returns error when thread not found" do
      assert {:error, :not_found} = Control.resume("nonexistent")
    end
  end

  describe "abandon/1" do
    test "transitions thread to abandoned state" do
      thread = insert_thread("executing", owner: "worker-123")

      assert {:ok, _msg} = Control.abandon(thread.id)

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "abandoned"
    end

    test "clears owner on abandon" do
      thread = insert_thread("executing", owner: "worker-123")

      assert {:ok, _msg} = Control.abandon(thread.id)

      updated = Repo.get!(Thread, thread.id)
      assert is_nil(updated.owner)
    end

    test "returns error when thread not found" do
      assert {:error, :not_found} = Control.abandon("99999999")
    end

    test "returns error for illegal transition (already done)" do
      thread = insert_thread("done")

      assert {:error, _reason} = Control.abandon(thread.id)
    end
  end
end
