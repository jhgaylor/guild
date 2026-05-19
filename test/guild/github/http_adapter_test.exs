defmodule Guild.GitHub.HttpAdapterTest do
  use ExUnit.Case, async: false

  alias Guild.GitHub.HttpAdapter

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    # Pre-seed a valid installation token so auth exchange is skipped
    expiry = System.system_time(:second) + 3600
    :persistent_term.put({HttpAdapter, :token}, {"test-token", expiry})

    # Point the adapter at Bypass
    System.put_env("GITHUB_BASE_URL", base_url)

    on_exit(fn ->
      :persistent_term.erase({HttpAdapter, :token})
      System.delete_env("GITHUB_BASE_URL")
    end)

    {:ok, bypass: bypass}
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # ---------------------------------------------------------------------------
  # get_issue
  # ---------------------------------------------------------------------------

  describe "get_issue/2" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 200, %{"number" => 3, "title" => "Test issue"})
      end)

      assert {:ok, %{"number" => 3}} = HttpAdapter.get_issue("jhgaylor/guild", 3)
    end

    test "returns {:error, :transient, :rate_limited} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 429, %{"message" => "rate limited"})
      end)

      assert {:error, :transient, :rate_limited} = HttpAdapter.get_issue("jhgaylor/guild", 3)
    end

    test "returns {:error, :permanent, :not_found} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} = HttpAdapter.get_issue("jhgaylor/guild", 3)
    end

    test "returns {:error, :transient, :server_error} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 500, %{"message" => "Internal Server Error"})
      end)

      assert {:error, :transient, :server_error} = HttpAdapter.get_issue("jhgaylor/guild", 3)
    end

    test "returns {:error, :permanent, :forbidden} on 403", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 403, %{"message" => "Forbidden"})
      end)

      assert {:error, :permanent, :forbidden} = HttpAdapter.get_issue("jhgaylor/guild", 3)
    end

    test "returns {:error, :unexpected, {:unknown_status, 418}} on 418", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 418, %{"message" => "I'm a teapot"})
      end)

      assert {:error, :unexpected, {:unknown_status, 418}} =
               HttpAdapter.get_issue("jhgaylor/guild", 3)
    end
  end

  # ---------------------------------------------------------------------------
  # assign_to_self
  # ---------------------------------------------------------------------------

  describe "assign_to_self/2" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 200, %{"number" => 3, "assignees" => [%{"login" => "guild-bot"}]})
      end)

      assert {:ok, _} = HttpAdapter.assign_to_self("jhgaylor/guild", 3)
    end

    test "returns {:error, :transient, :rate_limited} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 429, %{})
      end)

      assert {:error, :transient, :rate_limited} = HttpAdapter.assign_to_self("jhgaylor/guild", 3)
    end

    test "returns {:error, :transient, :server_error} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 500, %{})
      end)

      assert {:error, :transient, :server_error} = HttpAdapter.assign_to_self("jhgaylor/guild", 3)
    end
  end

  # ---------------------------------------------------------------------------
  # comment_on_issue
  # ---------------------------------------------------------------------------

  describe "comment_on_issue/3" do
    test "returns {:ok, map} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/3/comments", fn conn ->
        json_resp(conn, 201, %{"id" => 42, "body" => "comment text"})
      end)

      assert {:ok, _} = HttpAdapter.comment_on_issue("jhgaylor/guild", 3, "comment text")
    end

    test "returns {:error, :permanent, :not_found} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/3/comments", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} =
               HttpAdapter.comment_on_issue("jhgaylor/guild", 3, "text")
    end
  end

  # ---------------------------------------------------------------------------
  # comment_on_pr
  # ---------------------------------------------------------------------------

  describe "comment_on_pr/3" do
    test "returns {:ok, map} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/5/comments", fn conn ->
        json_resp(conn, 201, %{"id" => 99})
      end)

      assert {:ok, _} = HttpAdapter.comment_on_pr("jhgaylor/guild", 5, "lgtm")
    end

    test "returns {:error, :permanent, :not_found} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/5/comments", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} = HttpAdapter.comment_on_pr("jhgaylor/guild", 5, "lgtm")
    end
  end

  # ---------------------------------------------------------------------------
  # create_branch
  # ---------------------------------------------------------------------------

  describe "create_branch/3" do
    test "returns {:ok, map} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/refs", fn conn ->
        json_resp(conn, 201, %{"ref" => "refs/heads/new-branch"})
      end)

      assert {:ok, _} = HttpAdapter.create_branch("jhgaylor/guild", "new-branch", "abc123")
    end

    test "returns {:error, :permanent, {:validation, _}} on 422", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/refs", fn conn ->
        json_resp(conn, 422, %{"message" => "Reference already exists"})
      end)

      assert {:error, :permanent, {:validation, _}} =
               HttpAdapter.create_branch("jhgaylor/guild", "existing", "abc123")
    end
  end

  # ---------------------------------------------------------------------------
  # open_pull_request
  # ---------------------------------------------------------------------------

  describe "open_pull_request/5" do
    test "returns {:ok, map} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/pulls", fn conn ->
        json_resp(conn, 201, %{
          "number" => 42,
          "html_url" => "https://github.com/jhgaylor/guild/pull/42"
        })
      end)

      assert {:ok, %{"number" => 42}} =
               HttpAdapter.open_pull_request("jhgaylor/guild", "title", "body", "head", "main")
    end

    test "returns {:error, :transient, :server_error} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/pulls", fn conn ->
        json_resp(conn, 500, %{})
      end)

      assert {:error, :transient, :server_error} =
               HttpAdapter.open_pull_request("jhgaylor/guild", "t", "b", "h", "main")
    end

    test "returns {:error, :transient, :rate_limited} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/pulls", fn conn ->
        json_resp(conn, 429, %{})
      end)

      assert {:error, :transient, :rate_limited} =
               HttpAdapter.open_pull_request("jhgaylor/guild", "t", "b", "h", "main")
    end
  end

  # ---------------------------------------------------------------------------
  # update_pull_request
  # ---------------------------------------------------------------------------

  describe "update_pull_request/3" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/pulls/42", fn conn ->
        json_resp(conn, 200, %{"number" => 42})
      end)

      assert {:ok, _} = HttpAdapter.update_pull_request("jhgaylor/guild", 42, %{title: "updated"})
    end
  end

  # ---------------------------------------------------------------------------
  # create_issue
  # ---------------------------------------------------------------------------

  describe "create_issue/6" do
    test "returns {:ok, map} on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues", fn conn ->
        json_resp(conn, 201, %{"number" => 10})
      end)

      assert {:ok, _} =
               HttpAdapter.create_issue("jhgaylor/guild", "title", "body", [], [], nil)
    end

    test "returns {:error, :permanent, :not_found} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} =
               HttpAdapter.create_issue("jhgaylor/guild", "t", "b", [], [], nil)
    end
  end

  # ---------------------------------------------------------------------------
  # create_sub_issue
  # ---------------------------------------------------------------------------

  describe "create_sub_issue/5" do
    test "creates regular issue with parent reference in body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(raw_body)
        assert String.contains?(decoded["body"], "Parent issue: #3")
        json_resp(conn, 201, %{"number" => 11})
      end)

      assert {:ok, _} =
               HttpAdapter.create_sub_issue("jhgaylor/guild", 3, "sub title", "sub body", [])
    end
  end

  # ---------------------------------------------------------------------------
  # update_issue
  # ---------------------------------------------------------------------------

  describe "update_issue/3" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 200, %{"number" => 3})
      end)

      assert {:ok, _} = HttpAdapter.update_issue("jhgaylor/guild", 3, %{title: "new title"})
    end
  end

  # ---------------------------------------------------------------------------
  # close_issue
  # ---------------------------------------------------------------------------

  describe "close_issue/3" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 200, %{"number" => 3, "state" => "closed"})
      end)

      assert {:ok, _} = HttpAdapter.close_issue("jhgaylor/guild", 3, "completed")
    end

    test "returns {:error, :transient, :server_error} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 500, %{})
      end)

      assert {:error, :transient, :server_error} =
               HttpAdapter.close_issue("jhgaylor/guild", 3, "completed")
    end
  end

  # ---------------------------------------------------------------------------
  # add_to_project
  # ---------------------------------------------------------------------------

  describe "add_to_project/3" do
    test "always returns {:error, :permanent, :not_configured}" do
      assert {:error, :permanent, :not_configured} =
               HttpAdapter.add_to_project("jhgaylor/guild", "node_id", "proj_id")
    end
  end

  # ---------------------------------------------------------------------------
  # update_issue_status
  # ---------------------------------------------------------------------------

  describe "update_issue_status/3" do
    test "returns {:ok, map} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/issues/3", fn conn ->
        json_resp(conn, 200, %{"number" => 3})
      end)

      assert {:ok, _} = HttpAdapter.update_issue_status("jhgaylor/guild", 3, "open")
    end
  end

  # ---------------------------------------------------------------------------
  # add_label
  # ---------------------------------------------------------------------------

  describe "add_label/3" do
    test "returns {:ok, list} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/3/labels", fn conn ->
        json_resp(conn, 200, [%{"name" => "bug"}])
      end)

      assert {:ok, _} = HttpAdapter.add_label("jhgaylor/guild", 3, ["bug"])
    end

    test "returns {:error, :transient, :rate_limited} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/3/labels", fn conn ->
        json_resp(conn, 429, %{})
      end)

      assert {:error, :transient, :rate_limited} =
               HttpAdapter.add_label("jhgaylor/guild", 3, ["bug"])
    end

    test "returns {:error, :permanent, :not_found} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/issues/3/labels", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} =
               HttpAdapter.add_label("jhgaylor/guild", 3, ["bug"])
    end
  end

  # ---------------------------------------------------------------------------
  # list_pull_requests
  # ---------------------------------------------------------------------------

  describe "list_pull_requests/2" do
    test "returns {:ok, list} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/pulls", fn conn ->
        json_resp(conn, 200, [%{"number" => 1, "html_url" => "https://github.com/jhgaylor/guild/pull/1"}])
      end)

      assert {:ok, [%{"number" => 1}]} = HttpAdapter.list_pull_requests("jhgaylor/guild", state: "open")
    end

    test "returns {:error, :transient, :server_error} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/pulls", fn conn ->
        json_resp(conn, 500, %{"message" => "Internal Server Error"})
      end)

      assert {:error, :transient, :server_error} =
               HttpAdapter.list_pull_requests("jhgaylor/guild", state: "open")
    end
  end

  # ---------------------------------------------------------------------------
  # token exchange via Bypass (Fix 2: real auth flow, no persistent_term seed)
  # ---------------------------------------------------------------------------

  @test_rsa_key """
  -----BEGIN PRIVATE KEY-----
  MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCsLE8uRNmFLiAw
  RslTXzSKW7ZK8DeYlHm5FNlxcNyRRSfXdD7MBleShv4vNAgdw+lxLMqfwXedCQ7i
  6MDoc9nsQb+KeuHZgVoIetl3JnZJYr029EfhbeqXivqXdCeEisWxgSyei9lzpmob
  ovMk0xwl2likIUGl4yomY6VSlrT5s/d5NmO0HKxjk4Sn5K/wx9ltlvn+J5kkbQNu
  BSYJRx2uOJgFNl2RODcbns2wZVI+6jYBZLTJJg2WJdZ02XokrnRe5JT5BB/YgrlX
  fcAPncRH+vpuRyIDtWAg01+ACe4xjDX7JzUzTUH+bprap7yrz48C8mE51QvmHPIq
  QwAq7yJRAgMBAAECggEAChVvmcJ3NEFMVKeArmewDb5rVx4/Pf921ZaEBGHbeTf3
  VRC+MM2E9CmrL3E5ByKXRIVJZME8U9qDoFneGn8r2et2irzBsi8iP8bk1QFQAjeh
  5LBlRAMKWfp4zMVadH0lhkzjeRxbDavxy6aSiQCYRcXw/8PhiBQIPvFXwxYyiUFJ
  Vn1pKSUbIT4u8KDblFU+YRvN5S6DntFUo/2o8Dc4V5SRNiNoTpg2c/HnIcUa1hRj
  YnCnFo3fIbIkmtZLS/AHXe9Dbpet4uase+e+fAQo4djh6U0P6abc2N13jse08dJs
  yDuBWmXhqT1XxMm8trPO4SfM2evKxPGg3caOcSe+8QKBgQDp6AoEqJVasusM1dN3
  dP0pNoQv/xaCvIYcxnvn1LUej4/FcLbcApS6jSTYbww/r/jZGesD9lvB8W3OEzfS
  bzDQo6FSdywjUmijyzYXP3JxPHqbzSCJVRa+nFDn8HnFa0E1YnalncEhzjIiDoai
  a//p3NuqIGKBgqiqQFbTt68xxQKBgQC8b4fyBv9raUuMgj8BIr4f0V9gqaWWX2Py
  anej25Z48QYCntx+mac35N4ySAYhIVMhRH2zog+GNXPId1B0lRl29X2Mrq2O7S0L
  ZNNLRwW2/7v3mEKBYUSJTZNyOxvcSK40giv/ZQtEEAWgEoaw4qWh7XaZ0P7MxKt+
  zK6CmH9zHQKBgQCvN2/Rv4tqDt7+lWq8cHl4Fut8nMR7GMgJ5DFLH86xXu9fAqko
  NBK/kB2Kt9zgFG0ADGc9Z52isb0EgubtDvftQrYE9Vqt9vyFviL91TxgUOKztTxr
  Q78u+B+vLze4yDhnyiOAuqTDMxfg5Sq7ntVslVJDpdDEnWDFcD7aiB2H1QKBgH9i
  pnRnZqQmOnxyUEVkR0MbN28RQG+3bMmkT9zlxYNc7MM4wbaUCQcwIUW8iug6rwf+
  VTvqgrQnzm3muu0VHnHc41MHgyzsCVd6gZySFrrvhxKKS+tK5hor51GBxAPW3m2A
  0l2E4WjRq/vailNp5K7i6Rpyvs2O5qCBnjeLAB3BAoGAJKGUcZ0o0eI0sBLMImNf
  EMczwWUoiQdk4lYtmhY8/Ue6sgpr0xuotXH4B2ol5XU25Q0I5EpxhNpd5NCJTijY
  EC3suidBfj6ZKMGj90TmA8U+atR06uEU5IUf2c3+r2WtCxIKXOP19RwwrtubsSux
  /d+bMh5BlXI1Ez/pj2RkkgI=
  -----END PRIVATE KEY-----
  """

  describe "token exchange via Bypass" do
    setup %{bypass: bypass} do
      # Override outer setup: remove pre-seeded token so the real exchange runs
      :persistent_term.erase({HttpAdapter, :token})

      System.put_env("GITHUB_APP_ID", "12345")
      System.put_env("GITHUB_PRIVATE_KEY", String.trim(@test_rsa_key))
      System.put_env("GITHUB_INSTALLATION_ID", "99999")

      Bypass.expect_once(bypass, "POST", "/app/installations/99999/access_tokens", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "token" => "bypass-test-token",
            "expires_at" => "2099-12-31T23:59:59Z"
          })
        )
      end)

      on_exit(fn ->
        System.delete_env("GITHUB_APP_ID")
        System.delete_env("GITHUB_PRIVATE_KEY")
        System.delete_env("GITHUB_INSTALLATION_ID")
      end)

      :ok
    end

    test "fetches installation token and uses it for subsequent calls", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/issues/1", fn conn ->
        json_resp(conn, 200, %{"number" => 1})
      end)

      assert {:ok, %{"number" => 1}} = HttpAdapter.get_issue("jhgaylor/guild", 1)
    end
  end

  # ---------------------------------------------------------------------------
  # push_to_branch / commit_and_push (multi-step smoke test)
  # ---------------------------------------------------------------------------

  describe "push_to_branch/4" do
    test "completes multi-step commit flow and returns {:ok, map}", %{bypass: bypass} do
      # Step 1: GET ref → base SHA
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/git/ref/heads/feat", fn conn ->
        json_resp(conn, 200, %{"object" => %{"sha" => "base-sha"}})
      end)

      # Step 2: POST blob
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/blobs", fn conn ->
        json_resp(conn, 201, %{"sha" => "blob-sha"})
      end)

      # Step 3: POST tree
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/trees", fn conn ->
        json_resp(conn, 201, %{"sha" => "tree-sha"})
      end)

      # Step 4: POST commit
      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/commits", fn conn ->
        json_resp(conn, 201, %{"sha" => "commit-sha"})
      end)

      # Step 5: PATCH ref
      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/git/refs/heads/feat", fn conn ->
        json_resp(conn, 200, %{"ref" => "refs/heads/feat"})
      end)

      assert {:ok, _} =
               HttpAdapter.push_to_branch(
                 "jhgaylor/guild",
                 "feat",
                 "add CONTRIBUTING.md",
                 [%{path: "CONTRIBUTING.md", content: "# Contributing\n"}]
               )
    end

    test "returns error if ref lookup fails", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/git/ref/heads/missing", fn conn ->
        json_resp(conn, 404, %{"message" => "Not Found"})
      end)

      assert {:error, :permanent, :not_found} =
               HttpAdapter.push_to_branch("jhgaylor/guild", "missing", "msg", [])
    end
  end

  describe "commit_and_push/4" do
    test "delegates to the same multi-step flow as push_to_branch", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/jhgaylor/guild/git/ref/heads/main", fn conn ->
        json_resp(conn, 200, %{"object" => %{"sha" => "sha1"}})
      end)

      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/blobs", fn conn ->
        json_resp(conn, 201, %{"sha" => "blob1"})
      end)

      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/trees", fn conn ->
        json_resp(conn, 201, %{"sha" => "tree1"})
      end)

      Bypass.expect_once(bypass, "POST", "/repos/jhgaylor/guild/git/commits", fn conn ->
        json_resp(conn, 201, %{"sha" => "commit1"})
      end)

      Bypass.expect_once(bypass, "PATCH", "/repos/jhgaylor/guild/git/refs/heads/main", fn conn ->
        json_resp(conn, 200, %{"ref" => "refs/heads/main"})
      end)

      assert {:ok, _} =
               HttpAdapter.commit_and_push(
                 "jhgaylor/guild",
                 "main",
                 "chore: update file",
                 [%{path: "README.md", content: "# Guild\n"}]
               )
    end
  end
end
