defmodule Guild.Primitives.Communication do
  @moduledoc """
  Communication primitives: GitHub comments (live) and Slack stubs (not configured).
  """

  defp github_adapter do
    Application.get_env(:guild, :github_adapter, Guild.GitHub.TestAdapter)
  end

  @doc "Post a comment on a GitHub issue."
  def comment_on_issue(repo, issue_number, body) do
    try do
      github_adapter().comment_on_issue(repo, issue_number, body)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Post a comment on a GitHub pull request."
  def comment_on_pr(repo, pr_number, body) do
    try do
      github_adapter().comment_on_pr(repo, pr_number, body)
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc "Reply in a Slack thread. Not yet configured."
  def reply_in_thread(_channel, _thread_ts, _body) do
    {:error, :permanent, :not_configured}
  end

  @doc "Post a message to a Slack channel. Not yet configured."
  def post_to_channel(_channel, _body) do
    {:error, :permanent, :not_configured}
  end
end
