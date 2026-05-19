defmodule Guild.GitHub.TestAdapter do
  @moduledoc """
  Test implementation of Guild.GitHub behaviour. Returns configurable responses
  from the process dictionary. Defaults to {:ok, %{}} for all callbacks.

  Use configure/2 in tests to set up specific responses:

      Guild.GitHub.TestAdapter.configure(:create_branch, {:error, :transient, :timeout})
  """

  @behaviour Guild.GitHub

  @default {:ok, %{}}

  @doc "Configure a callback to return a specific response for the current process."
  def configure(callback, response) do
    Process.put({__MODULE__, callback}, response)
  end

  @doc "Reset all configured responses."
  def reset do
    :ok
  end

  defp get_response(callback) do
    Process.get({__MODULE__, callback}, @default)
  end

  defp maybe_raise(response) do
    case response do
      {:raise, msg} -> raise RuntimeError, msg
      other -> other
    end
  end

  @impl Guild.GitHub
  def assign_to_self(_repo, _issue_number),
    do: maybe_raise(get_response(:assign_to_self))

  @impl Guild.GitHub
  def comment_on_issue(_repo, _issue_number, _body),
    do: maybe_raise(get_response(:comment_on_issue))

  @impl Guild.GitHub
  def comment_on_pr(_repo, _pr_number, _body),
    do: maybe_raise(get_response(:comment_on_pr))

  @impl Guild.GitHub
  def create_branch(_repo, _branch, _from_sha),
    do: maybe_raise(get_response(:create_branch))

  @impl Guild.GitHub
  def commit_and_push(_repo, _branch, _message, _files),
    do: maybe_raise(get_response(:commit_and_push))

  @impl Guild.GitHub
  def open_pull_request(_repo, _title, _body, _head, _base),
    do: maybe_raise(get_response(:open_pull_request))

  @impl Guild.GitHub
  def update_pull_request(_repo, _pr_number, _attrs),
    do: maybe_raise(get_response(:update_pull_request))

  @impl Guild.GitHub
  def push_to_branch(_repo, _branch, _message, _files),
    do: maybe_raise(get_response(:push_to_branch))

  @impl Guild.GitHub
  def create_issue(_repo, _title, _body, _labels, _assignees, _project_id),
    do: maybe_raise(get_response(:create_issue))

  @impl Guild.GitHub
  def create_sub_issue(_repo, _parent_number, _title, _body, _labels),
    do: maybe_raise(get_response(:create_sub_issue))

  @impl Guild.GitHub
  def update_issue(_repo, _issue_number, _attrs),
    do: maybe_raise(get_response(:update_issue))

  @impl Guild.GitHub
  def close_issue(_repo, _issue_number, _reason),
    do: maybe_raise(get_response(:close_issue))

  @impl Guild.GitHub
  def add_to_project(_repo, _issue_node_id, _project_id),
    do: maybe_raise(get_response(:add_to_project))

  @impl Guild.GitHub
  def update_issue_status(_repo, _issue_number, _status),
    do: maybe_raise(get_response(:update_issue_status))

  @impl Guild.GitHub
  def add_label(_repo, _issue_number, _labels),
    do: maybe_raise(get_response(:add_label))

  @impl Guild.GitHub
  def get_issue(_repo, issue_number) do
    case get_response(:get_issue) do
      {:ok, _} ->
        {:ok,
         %{
           title: "Test Issue",
           body: "Test body",
           number: issue_number,
           node_id: "node_#{issue_number}"
         }}

      other ->
        maybe_raise(other)
    end
  end

  @impl Guild.GitHub
  def list_pull_requests(_repo, _opts),
    do: maybe_raise(get_response(:list_pull_requests))
end
