defmodule Guild.Primitives.WorkManagement do
  @moduledoc """
  Work management primitives: assignment, status, and label management via GitHub.
  """

  defp github_adapter do
    Application.get_env(:guild, :github_adapter, Guild.GitHub.TestAdapter)
  end

  @doc "Assign an issue to the configured worker identity (self)."
  def assign_to_self(repo, issue_number) do
    try do
      github_adapter().assign_to_self(repo, issue_number)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Update the status of an issue (e.g. GitHub Projects status field)."
  def update_issue_status(repo, issue_number, status) do
    try do
      github_adapter().update_issue_status(repo, issue_number, status)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Add labels to an issue."
  def add_label(repo, issue_number, labels) do
    try do
      github_adapter().add_label(repo, issue_number, labels)
    rescue
      e -> {:error, :unexpected, e}
    end
  end
end
