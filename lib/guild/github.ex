defmodule Guild.GitHub do
  @moduledoc """
  Behaviour for GitHub API operations. All callbacks return typed error tuples
  per ADR 0008: {:ok, map()} | {:error, :transient | :permanent | :unexpected, term()}.
  """

  @type error_tier :: :transient | :permanent | :unexpected
  @type result :: {:ok, map()} | {:error, error_tier(), term()}

  @callback assign_to_self(repo :: String.t(), issue_number :: integer()) :: result()

  @callback comment_on_issue(repo :: String.t(), issue_number :: integer(), body :: String.t()) ::
              result()

  @callback comment_on_pr(repo :: String.t(), pr_number :: integer(), body :: String.t()) ::
              result()

  @callback create_branch(repo :: String.t(), branch :: String.t(), from_sha :: String.t()) ::
              result()

  @callback commit_and_push(
              repo :: String.t(),
              branch :: String.t(),
              message :: String.t(),
              files :: list()
            ) :: result()

  @callback open_pull_request(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              head :: String.t(),
              base :: String.t()
            ) :: result()

  @callback update_pull_request(repo :: String.t(), pr_number :: integer(), attrs :: map()) ::
              result()

  @callback push_to_branch(
              repo :: String.t(),
              branch :: String.t(),
              message :: String.t(),
              files :: list()
            ) :: result()

  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              labels :: list(),
              assignees :: list(),
              project_id :: String.t() | nil
            ) :: result()

  @callback create_sub_issue(
              repo :: String.t(),
              parent_number :: integer(),
              title :: String.t(),
              body :: String.t(),
              labels :: list()
            ) :: result()

  @callback update_issue(repo :: String.t(), issue_number :: integer(), attrs :: map()) ::
              result()

  @callback close_issue(
              repo :: String.t(),
              issue_number :: integer(),
              reason :: String.t()
            ) :: result()

  @callback add_to_project(
              repo :: String.t(),
              issue_node_id :: String.t(),
              project_id :: String.t()
            ) :: result()

  @callback update_issue_status(
              repo :: String.t(),
              issue_number :: integer(),
              status :: String.t()
            ) :: result()

  @callback add_label(repo :: String.t(), issue_number :: integer(), labels :: list()) ::
              result()
end
