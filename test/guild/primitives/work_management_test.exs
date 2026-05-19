defmodule Guild.Primitives.WorkManagementTest do
  use ExUnit.Case, async: false

  alias Guild.GitHub.TestAdapter
  alias Guild.Primitives.WorkManagement

  describe "assign_to_self/2" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:assign_to_self, {:ok, %{"assignees" => ["bot"]}})
      assert {:ok, _} = WorkManagement.assign_to_self("org/repo", 1)
    end

    test "propagates :transient error" do
      TestAdapter.configure(:assign_to_self, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = WorkManagement.assign_to_self("org/repo", 1)
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:assign_to_self, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = WorkManagement.assign_to_self("org/repo", 1)
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:assign_to_self, {:raise, "err"})
      assert {:error, :unexpected, _} = WorkManagement.assign_to_self("org/repo", 1)
    end
  end

  describe "update_issue_status/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:update_issue_status, {:ok, %{"status" => "in_progress"}})
      assert {:ok, _} = WorkManagement.update_issue_status("org/repo", 1, "in_progress")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:update_issue_status, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = WorkManagement.update_issue_status("org/repo", 1, "s")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:update_issue_status, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = WorkManagement.update_issue_status("org/repo", 1, "s")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:update_issue_status, {:raise, "err"})
      assert {:error, :unexpected, _} = WorkManagement.update_issue_status("org/repo", 1, "s")
    end
  end

  describe "add_label/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:add_label, {:ok, %{"labels" => ["bug"]}})
      assert {:ok, _} = WorkManagement.add_label("org/repo", 1, ["bug"])
    end

    test "propagates :transient error" do
      TestAdapter.configure(:add_label, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = WorkManagement.add_label("org/repo", 1, ["l"])
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:add_label, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = WorkManagement.add_label("org/repo", 1, ["l"])
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:add_label, {:raise, "err"})
      assert {:error, :unexpected, _} = WorkManagement.add_label("org/repo", 1, ["l"])
    end
  end
end
