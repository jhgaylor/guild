defmodule Guild.Primitives.CommunicationTest do
  use ExUnit.Case, async: false

  alias Guild.GitHub.TestAdapter
  alias Guild.Primitives.Communication

  describe "comment_on_issue/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:comment_on_issue, {:ok, %{"id" => 1}})
      assert {:ok, _} = Communication.comment_on_issue("org/repo", 1, "hello")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:comment_on_issue, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Communication.comment_on_issue("org/repo", 1, "hi")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:comment_on_issue, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Communication.comment_on_issue("org/repo", 1, "hi")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:comment_on_issue, {:raise, "err"})
      assert {:error, :unexpected, _} = Communication.comment_on_issue("org/repo", 1, "hi")
    end
  end

  describe "comment_on_pr/3" do
    test "returns {:ok, _} on success" do
      TestAdapter.configure(:comment_on_pr, {:ok, %{"id" => 2}})
      assert {:ok, _} = Communication.comment_on_pr("org/repo", 1, "lgtm")
    end

    test "propagates :transient error" do
      TestAdapter.configure(:comment_on_pr, {:error, :transient, :timeout})
      assert {:error, :transient, :timeout} = Communication.comment_on_pr("org/repo", 1, "hi")
    end

    test "propagates :permanent error" do
      TestAdapter.configure(:comment_on_pr, {:error, :permanent, :not_found})
      assert {:error, :permanent, :not_found} = Communication.comment_on_pr("org/repo", 1, "hi")
    end

    test "returns :unexpected on raised exception" do
      TestAdapter.configure(:comment_on_pr, {:raise, "err"})
      assert {:error, :unexpected, _} = Communication.comment_on_pr("org/repo", 1, "hi")
    end
  end

  describe "reply_in_thread/3" do
    test "always returns :permanent :not_configured" do
      assert {:error, :permanent, :not_configured} =
               Communication.reply_in_thread("C123", "ts123", "body")
    end
  end

  describe "post_to_channel/2" do
    test "always returns :permanent :not_configured" do
      assert {:error, :permanent, :not_configured} =
               Communication.post_to_channel("C123", "hello world")
    end
  end
end
