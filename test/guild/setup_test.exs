defmodule Guild.SetupTest do
  use Guild.DataCase

  describe "gaps/0" do
    setup do
      on_exit(fn ->
        Guild.Repo.delete_all(Guild.Schema.Repo)
        Guild.Repo.delete_all(Guild.Schema.Worker)
      end)
      :ok
    end

    test "returns [:no_repos, :no_workers] when both are empty" do
      gaps = Guild.Setup.gaps()
      assert :no_repos in gaps
      assert :no_workers in gaps
    end

    test "returns [] when at least one enabled repo and one worker exist" do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-id",
        vault_id: "vault-id"
      })
      Guild.Repo.insert!(%Guild.Schema.Repo{
        full_name: "owner/repo",
        worker_id: "test-worker",
        enabled: true
      })
      assert Guild.Setup.gaps() == []
    end

    test "returns :no_repos when all repos are disabled" do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-id",
        vault_id: "vault-id"
      })
      Guild.Repo.insert!(%Guild.Schema.Repo{
        full_name: "owner/repo",
        worker_id: "test-worker",
        enabled: false
      })
      gaps = Guild.Setup.gaps()
      assert :no_repos in gaps
    end
  end
end
