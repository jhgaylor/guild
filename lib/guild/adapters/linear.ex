defmodule Guild.Adapters.Linear do
  @moduledoc """
  Linear adapter for managing issues via the Linear GraphQL API.

  Reads LINEAR_API_KEY and LINEAR_TEAM_ID from environment variables.
  Returns {:ok, :not_configured} gracefully when credentials are absent.
  """

  require Logger

  @linear_api_url "https://api.linear.app/graphql"

  defp api_key do
    Application.get_env(:guild, :linear_api_key) ||
      System.get_env("LINEAR_API_KEY")
  end

  defp team_id do
    Application.get_env(:guild, :linear_team_id) ||
      System.get_env("LINEAR_TEAM_ID")
  end

  defp configured? do
    not is_nil(api_key()) and not is_nil(team_id())
  end

  defp api_url do
    Application.get_env(:guild, :linear_api_url, @linear_api_url)
  end

  defp headers do
    [
      {"Authorization", api_key()},
      {"Content-Type", "application/json"}
    ]
  end

  defp graphql_request(query, variables) do
    body = Jason.encode!(%{query: query, variables: variables})

    try do
      case HTTPoison.post(api_url(), body, headers()) do
        {:ok, %{status_code: status} = response} when status in 200..299 ->
          case Jason.decode(response.body) do
            {:ok, %{"errors" => errors}} when is_list(errors) and length(errors) > 0 ->
              Logger.warning("Linear GraphQL errors: #{inspect(errors)}")
              {:error, :permanent, {:graphql_errors, errors}}

            {:ok, decoded} ->
              {:ok, decoded}

            {:error, _} ->
              {:error, :unexpected, :invalid_json}
          end

        {:ok, %{status_code: status}} when status >= 500 ->
          {:error, :transient, {:http_error, status}}

        {:ok, %{status_code: 429}} ->
          {:error, :transient, {:http_error, 429}}

        {:ok, %{status_code: status}} ->
          {:error, :permanent, {:http_error, status}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, :transient, reason}
      end
    rescue
      e -> {:error, :unexpected, e}
    end
  end

  @doc """
  Create a Linear issue.

  attrs may include: title, description.
  Returns {:ok, %{id: issue_id}} | {:ok, :not_configured} | {:error, tier, reason}.
  """
  def create_issue(attrs) do
    unless configured?() do
      {:ok, :not_configured}
    else
      title = Map.get(attrs, :title, Map.get(attrs, "title", "Untitled"))
      description = Map.get(attrs, :description, Map.get(attrs, "description", ""))

      query = """
      mutation CreateIssue($teamId: String!, $title: String!, $description: String) {
        issueCreate(input: {teamId: $teamId, title: $title, description: $description}) {
          success
          issue {
            id
            title
          }
        }
      }
      """

      variables = %{
        teamId: team_id(),
        title: title,
        description: description
      }

      case graphql_request(query, variables) do
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => id}}}}} ->
          {:ok, %{id: id}}

        {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}} ->
          {:error, :permanent, :create_failed}

        {:ok, response} ->
          Logger.warning("Unexpected Linear createIssue response: #{inspect(response)}")
          {:error, :unexpected, :unexpected_response_shape}

        error ->
          error
      end
    end
  end

  @doc """
  Update a Linear issue.

  attrs may include: stateId, state_name (e.g. "In Progress", "Done").
  Returns {:ok, %{id: issue_id}} | {:ok, :not_configured} | {:error, tier, reason}.
  """
  def update_issue(issue_id, attrs) do
    unless configured?() do
      {:ok, :not_configured}
    else
      input =
        attrs
        |> Enum.reduce(%{}, fn
          {:stateId, v}, acc -> Map.put(acc, :stateId, v)
          {"stateId", v}, acc -> Map.put(acc, :stateId, v)
          {:title, v}, acc -> Map.put(acc, :title, v)
          {"title", v}, acc -> Map.put(acc, :title, v)
          {:description, v}, acc -> Map.put(acc, :description, v)
          {"description", v}, acc -> Map.put(acc, :description, v)
          _, acc -> acc
        end)

      query = """
      mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) {
          success
          issue {
            id
            title
          }
        }
      }
      """

      variables = %{id: issue_id, input: input}

      case graphql_request(query, variables) do
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} ->
          {:ok, %{id: id}}

        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}} ->
          {:error, :permanent, :update_failed}

        {:ok, response} ->
          Logger.warning("Unexpected Linear updateIssue response: #{inspect(response)}")
          {:error, :unexpected, :unexpected_response_shape}

        error ->
          error
      end
    end
  end
end
