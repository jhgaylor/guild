defmodule Guild.GitHub.HttpAdapter do
  @moduledoc """
  Real GitHub API adapter using GitHub App authentication.

  Auth flow: App ID + private key → RS256 JWT → installation access token
  (cached in :persistent_term, refreshed 60 s before expiry).

  All callbacks return typed error tuples per ADR 0008:
    {:ok, map()} | {:error, :transient | :permanent | :unexpected, term()}
  """

  @behaviour Guild.GitHub

  # ---------------------------------------------------------------------------
  # Auth
  # ---------------------------------------------------------------------------

  defp generate_jwt do
    app_id = System.get_env("GITHUB_APP_ID")
    # GITHUB_PRIVATE_KEY may be stored with literal \n — convert to real newlines
    private_key =
      System.get_env("GITHUB_PRIVATE_KEY") |> String.replace("\\n", "\n")

    now = System.system_time(:second)
    claims = %{"iss" => app_id, "iat" => now - 60, "exp" => now + 600}
    signer = Joken.Signer.create("RS256", %{"pem" => private_key})
    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, signer)
    token
  end

  defp get_installation_token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      {token, expiry} when expiry > System.system_time(:second) + 60 ->
        token

      _ ->
        jwt = generate_jwt()
        installation_id = System.get_env("GITHUB_INSTALLATION_ID")
        base = System.get_env("GITHUB_BASE_URL") || "https://api.github.com"
        url = "#{base}/app/installations/#{installation_id}/access_tokens"

        headers = [
          {"Authorization", "Bearer #{jwt}"},
          {"Accept", "application/vnd.github+json"},
          {"X-GitHub-Api-Version", "2022-11-28"}
        ]

        {:ok, %{body: body}} = HTTPoison.post(url, "", headers)
        %{"token" => token, "expires_at" => expires_at_str} = Jason.decode!(body)
        expiry = expires_at_str |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()
        :persistent_term.put({__MODULE__, :token}, {token, expiry})
        token
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helper
  # ---------------------------------------------------------------------------

  defp github_base_url do
    # Allow tests (or custom deployments) to override the GitHub API base URL.
    System.get_env("GITHUB_BASE_URL") || "https://api.github.com"
  end

  defp github_request(method, path, body \\ "") do
    token = get_installation_token()
    url = "#{github_base_url()}#{path}"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"Content-Type", "application/json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]

    result =
      case method do
        :get -> HTTPoison.get(url, headers)
        :post -> HTTPoison.post(url, Jason.encode!(body), headers)
        :patch -> HTTPoison.patch(url, Jason.encode!(body), headers)
      end

    case result do
      {:ok, %{status_code: code, body: resp_body}} when code in 200..299 ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %{status_code: 429}} ->
        {:error, :transient, :rate_limited}

      {:ok, %{status_code: code}} when code in 500..599 ->
        {:error, :transient, :server_error}

      {:ok, %{status_code: 404}} ->
        {:error, :permanent, :not_found}

      {:ok, %{status_code: 403}} ->
        {:error, :permanent, :forbidden}

      {:ok, %{status_code: 422, body: b}} ->
        {:error, :permanent, {:validation, Jason.decode!(b)}}

      {:ok, %{status_code: code}} ->
        {:error, :unexpected, {:unknown_status, code}}

      {:error, reason} ->
        {:error, :transient, {:network, reason}}
    end
  end

  defp worker_identity, do: Application.get_env(:guild, :worker_identity, "guild-bot")

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl Guild.GitHub
  def get_issue(repo, issue_number) do
    github_request(:get, "/repos/#{repo}/issues/#{issue_number}")
  end

  @impl Guild.GitHub
  def assign_to_self(repo, issue_number) do
    github_request(:patch, "/repos/#{repo}/issues/#{issue_number}", %{
      assignees: [worker_identity()]
    })
  end

  @impl Guild.GitHub
  def comment_on_issue(repo, issue_number, body) do
    github_request(:post, "/repos/#{repo}/issues/#{issue_number}/comments", %{body: body})
  end

  @impl Guild.GitHub
  def comment_on_pr(repo, pr_number, body) do
    # GitHub uses the issues endpoint for PR comments
    github_request(:post, "/repos/#{repo}/issues/#{pr_number}/comments", %{body: body})
  end

  @impl Guild.GitHub
  def create_branch(repo, branch, from_sha) do
    github_request(:post, "/repos/#{repo}/git/refs", %{
      ref: "refs/heads/#{branch}",
      sha: from_sha
    })
  end

  @impl Guild.GitHub
  def commit_and_push(repo, branch, message, files) do
    do_commit_and_push(repo, branch, message, files)
  end

  @impl Guild.GitHub
  def push_to_branch(repo, branch, message, files) do
    do_commit_and_push(repo, branch, message, files)
  end

  defp do_commit_and_push(repo, branch, message, files) do
    with {:ok, ref_data} <- github_request(:get, "/repos/#{repo}/git/ref/heads/#{branch}"),
         base_sha <- get_in(ref_data, ["object", "sha"]),
         {:ok, blobs} <- create_blobs(repo, files),
         {:ok, tree_data} <-
           github_request(:post, "/repos/#{repo}/git/trees", %{
             base_tree: base_sha,
             tree: blobs
           }),
         tree_sha <- tree_data["sha"],
         {:ok, commit_data} <-
           github_request(:post, "/repos/#{repo}/git/commits", %{
             message: message,
             tree: tree_sha,
             parents: [base_sha]
           }),
         commit_sha <- commit_data["sha"] do
      github_request(:patch, "/repos/#{repo}/git/refs/heads/#{branch}", %{sha: commit_sha})
    end
  end

  defp create_blobs(repo, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      path = if is_map(file), do: file["path"] || file[:path], else: elem(file, 0)
      content = if is_map(file), do: file["content"] || file[:content], else: elem(file, 1)

      case github_request(:post, "/repos/#{repo}/git/blobs", %{
             content: content,
             encoding: "utf-8"
           }) do
        {:ok, blob} ->
          entry = %{path: path, mode: "100644", type: "blob", sha: blob["sha"]}
          {:cont, {:ok, [entry | acc]}}

        error ->
          {:halt, error}
      end
    end)
  end

  @impl Guild.GitHub
  def open_pull_request(repo, title, body, head, base) do
    github_request(:post, "/repos/#{repo}/pulls", %{
      title: title,
      body: body,
      head: head,
      base: base
    })
  end

  @impl Guild.GitHub
  def update_pull_request(repo, pr_number, attrs) do
    github_request(:patch, "/repos/#{repo}/pulls/#{pr_number}", attrs)
  end

  @impl Guild.GitHub
  def create_issue(repo, title, body, labels, assignees, _project_id) do
    github_request(:post, "/repos/#{repo}/issues", %{
      title: title,
      body: body,
      labels: labels,
      assignees: assignees
    })
  end

  @impl Guild.GitHub
  def create_sub_issue(repo, parent_number, title, body, labels) do
    # GitHub has no native sub-issue API — create as regular issue with parent reference
    full_body = "Parent issue: ##{parent_number}\n\n#{body}"

    github_request(:post, "/repos/#{repo}/issues", %{
      title: title,
      body: full_body,
      labels: labels
    })
  end

  @impl Guild.GitHub
  def update_issue(repo, issue_number, attrs) do
    github_request(:patch, "/repos/#{repo}/issues/#{issue_number}", attrs)
  end

  @impl Guild.GitHub
  def close_issue(repo, issue_number, _reason) do
    github_request(:patch, "/repos/#{repo}/issues/#{issue_number}", %{state: "closed"})
  end

  @impl Guild.GitHub
  def add_to_project(_repo, _issue_node_id, _project_id) do
    # GraphQL required — out of scope
    {:error, :permanent, :not_configured}
  end

  @impl Guild.GitHub
  def update_issue_status(repo, issue_number, status) do
    github_request(:patch, "/repos/#{repo}/issues/#{issue_number}", %{state: status})
  end

  @impl Guild.GitHub
  def add_label(repo, issue_number, labels) do
    github_request(:post, "/repos/#{repo}/issues/#{issue_number}/labels", %{labels: labels})
  end
end
