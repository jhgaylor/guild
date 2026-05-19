defmodule Guild.Primitives.CodeTest do
  use Guild.DataCase, async: false

  alias Guild.GitHub.TestAdapter
  alias Guild.Primitives.Code

  setup do
    # Reset adapter configuration before each test
    :ok
  end

  describe "create_branch/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:create_branch, {:ok, %{"ref" => "refs/heads/test"}})
      assert {:ok, _} = Code.create_branch("org/repo", "test-branch", "abc123")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:create_branch, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Code.create_branch("org/repo", "test", "sha")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:create_branch, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Code.create_branch("org/repo", "test", "sha")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:create_branch, {:raise, "boom"})
      assert {:error, :unexpected, _} = Code.create_branch("org/repo", "test", "sha")
    end
  end

  describe "commit_and_push/4" do
    test "returns {:ok, _} and inserts commit artifact" do
      TestAdapter.configure(:commit_and_push, {:ok, %{"sha" => "deadbeef", "html_url" => "http://example.com"}})
      assert {:ok, result} = Code.commit_and_push("org/repo", "main", "feat: add file", [])
      assert result["sha"] == "deadbeef"
    end

    test "propagates :transient error without inserting artifact" do
      TestAdapter.configure(:commit_and_push, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Code.commit_and_push("org/repo", "main", "msg", [])
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:commit_and_push, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Code.commit_and_push("org/repo", "main", "msg", [])
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:commit_and_push, {:raise, "db exploded"})
      assert {:error, :unexpected, _} = Code.commit_and_push("org/repo", "main", "msg", [])
    end
  end

  describe "open_pull_request/5" do
    test "returns {:ok, _} and inserts PR artifact" do
      TestAdapter.configure(:open_pull_request, {:ok, %{"number" => 42, "html_url" => "http://example.com/pr/42"}})
      assert {:ok, result} = Code.open_pull_request("org/repo", "title", "body", "head", "main")
      assert result["number"] == 42
    end

    test "propagates :transient error" do
      TestAdapter.configure(:open_pull_request, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Code.open_pull_request("org/repo", "t", "b", "h", "m")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:open_pull_request, {:error, :permanent, :validation_failed})
      assert {:error, :permanent, :validation_failed} = Code.open_pull_request("org/repo", "t", "b", "h", "m")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:open_pull_request, {:raise, "oops"})
      assert {:error, :unexpected, _} = Code.open_pull_request("org/repo", "t", "b", "h", "m")
    end
  end

  describe "update_pull_request/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:update_pull_request, {:ok, %{"number" => 1}})
      assert {:ok, _} = Code.update_pull_request("org/repo", 1, %{title: "new title"})
    end

    test "propagates :transient error" do
      TestAdapter.configure(:update_pull_request, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Code.update_pull_request("org/repo", 1, %{})
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:update_pull_request, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Code.update_pull_request("org/repo", 1, %{})
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:update_pull_request, {:raise, "err"})
      assert {:error, :unexpected, _} = Code.update_pull_request("org/repo", 1, %{})
    end
  end

  describe "push_to_branch/4" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:push_to_branch, {:ok, %{"sha" => "cafebabe", "html_url" => "http://example.com"}})
      assert {:ok, _} = Code.push_to_branch("org/repo", "branch", "msg", [])
    end

    test "propagates :transient error" do
      TestAdapter.configure(:push_to_branch, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Code.push_to_branch("org/repo", "b", "m", [])
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:push_to_branch, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Code.push_to_branch("org/repo", "b", "m", [])
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:push_to_branch, {:raise, "err"})
      assert {:error, :unexpected, _} = Code.push_to_branch("org/repo", "b", "m", [])
    end
  end
end
