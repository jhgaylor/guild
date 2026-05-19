defmodule Guild.Primitives.Code do
  @moduledoc """
  Code primitives: branch management, commits, and pull requests.
  Delegates to the configured Guild.GitHub implementation.
  """

  defp github_adapter do
    Application.get_env(:guild, :github_adapter, Guild.GitHub.TestAdapter)
  end

  @doc "Create a new branch from the given SHA."
  def create_branch(repo, branch, from_sha) do
    try do
      github_adapter().create_branch(repo, branch, from_sha)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Commit files and push to a branch."
  def commit_and_push(repo, branch, message, files) do
    try do
      github_adapter().commit_and_push(repo, branch, message, files)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Open a pull request."
  def open_pull_request(repo, title, body, head, base) do
    try do
      github_adapter().open_pull_request(repo, title, body, head, base)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Update an existing pull request."
  def update_pull_request(repo, pr_number, attrs) do
    try do
      github_adapter().update_pull_request(repo, pr_number, attrs)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Push files to an existing branch."
  def push_to_branch(repo, branch, message, files) do
    try do
      github_adapter().push_to_branch(repo, branch, message, files)
    rescue
      e -> {:error, :unexpected, e}
    end
  end
end
