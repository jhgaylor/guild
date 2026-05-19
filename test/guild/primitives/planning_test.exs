defmodule Guild.Primitives.PlanningTest do
  use ExUnit.Case, async: false

  alias Guild.GitHub.TestAdapter
  alias Guild.Primitives.Planning

  describe "create_issue/6" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:create_issue, {:ok, %{"number" => 10}})
      assert {:ok, _} = Planning.create_issue("org/repo", "title", "body", [], [], nil)
    end

    test "propagates :transient error" do
      TestAdapter.configure(:create_issue, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Planning.create_issue("org/repo", "t", "b", [], [], nil)
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:create_issue, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Planning.create_issue("org/repo", "t", "b", [], [], nil)
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:create_issue, {:raise, "err"})
      assert {:error, :unexpected, _} = Planning.create_issue("org/repo", "t", "b", [], [], nil)
    end
  end

  describe "create_sub_issue/5" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:create_sub_issue, {:ok, %{"number" => 11}})
      assert {:ok, _} = Planning.create_sub_issue("org/repo", 10, "title", "body", [])
    end

    test "propagates :transient error" do
      TestAdapter.configure(:create_sub_issue, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Planning.create_sub_issue("org/repo", 10, "t", "b", [])
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:create_sub_issue, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Planning.create_sub_issue("org/repo", 10, "t", "b", [])
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:create_sub_issue, {:raise, "err"})
      assert {:error, :unexpected, _} = Planning.create_sub_issue("org/repo", 10, "t", "b", [])
    end
  end

  describe "update_issue/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:update_issue, {:ok, %{"number" => 1}})
      assert {:ok, _} = Planning.update_issue("org/repo", 1, %{title: "new"})
    end

    test "propagates :transient error" do
      TestAdapter.configure(:update_issue, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Planning.update_issue("org/repo", 1, %{})
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:update_issue, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Planning.update_issue("org/repo", 1, %{})
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:update_issue, {:raise, "err"})
      assert {:error, :unexpected, _} = Planning.update_issue("org/repo", 1, %{})
    end
  end

  describe "close_issue/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:close_issue, {:ok, %{"number" => 1}})
      assert {:ok, _} = Planning.close_issue("org/repo", 1, "completed")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:close_issue, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Planning.close_issue("org/repo", 1, "r")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:close_issue, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Planning.close_issue("org/repo", 1, "r")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:close_issue, {:raise, "err"})
      assert {:error, :unexpected, _} = Planning.close_issue("org/repo", 1, "r")
    end
  end

  describe "add_to_project/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:add_to_project, {:ok, %{"id" => "PVT_xxx"}})
      assert {:ok, _} = Planning.add_to_project("org/repo", "node_id", "project_id")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:add_to_project, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Planning.add_to_project("org/repo", "n", "p")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:add_to_project, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Planning.add_to_project("org/repo", "n", "p")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:add_to_project, {:raise, "err"})
      assert {:error, :unexpected, _} = Planning.add_to_project("org/repo", "n", "p")
    end
  end
end
