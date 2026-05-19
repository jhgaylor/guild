defmodule Guild.Primitives.Planning do
  @moduledoc """
  Planning primitives: issue management via GitHub.
  Delegates to the configured Guild.GitHub implementation.
  """

  defp github_adapter do
    Application.get_env(:guild, :github_adapter, Guild.GitHub.TestAdapter)
  end

  @doc "Create a new issue on GitHub."
  def create_issue(repo, title, body, labels, assignees, project_id) do
    try do
      github_adapter().create_issue(repo, title, body, labels, assignees, project_id)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Create a sub-issue under a parent issue."
  def create_sub_issue(repo, parent_number, title, body, labels) do
    try do
      github_adapter().create_sub_issue(repo, parent_number, title, body, labels)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Update an existing issue."
  def update_issue(repo, issue_number, attrs) do
    try do
      github_adapter().update_issue(repo, issue_number, attrs)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Close an issue with the given reason."
  def close_issue(repo, issue_number, reason) do
    try do
      github_adapter().close_issue(repo, issue_number, reason)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Add an issue to a GitHub Project."
  def add_to_project(repo, issue_node_id, project_id) do
    try do
      github_adapter().add_to_project(repo, issue_node_id, project_id)
    rescue
      e -> {:error, :unexpected, e}
    end
  end
end
