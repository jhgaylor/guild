defmodule Guild.StartupRecoveryTest do
  use Guild.DataCase, async: false

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.StartupRecovery

  @worker_identity Application.compile_env(:guild, :worker_identity, "guild-bot")

  defp insert_thread(attrs) do
    defaults = %{
      anchor_type: "github_issue",
      anchor_id: "issue_#{System.unique_integer([:positive])}",
      anchor_url: "https://github.com/test/repo/issues/1",
      state: "noticed",
      owner: @worker_identity
    }

    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    thread
  end

  describe "recover/0" do
    test "returns {:ok, 2} with 2 non-terminal threads owned by configured worker" do
      # 2 non-terminal threads owned by configured worker identity
      insert_thread(%{state: "noticed", owner: @worker_identity})
      insert_thread(%{state: "executing", owner: @worker_identity})

      # 1 terminal thread owned by configured worker — must NOT be counted
      insert_thread(%{state: "done", owner: @worker_identity})

      # 1 non-terminal thread owned by a different identity — must NOT be counted
      insert_thread(%{state: "noticed", owner: "some-other-bot"})

      assert {:ok, 2} = StartupRecovery.recover()
    end

    test "returns {:ok, 0} when no matching threads exist" do
      assert {:ok, 0} = StartupRecovery.recover()
    end

    test "counts threads in all active states owned by configured worker" do
      for state <- ~w(unnoticed noticed claimed executing pr_open blocked planned) do
        insert_thread(%{state: state, owner: @worker_identity})
      end

      # 1 terminal per type — should not be counted
      insert_thread(%{state: "done", owner: @worker_identity})
      insert_thread(%{state: "abandoned", owner: @worker_identity})

      assert {:ok, 7} = StartupRecovery.recover()
    end
  end
end
