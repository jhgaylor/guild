defmodule Guild.Adapters.LinearTest do
  use ExUnit.Case, async: true

  alias Guild.Adapters.Linear

  describe "create_issue/1 — not configured" do
    test "returns {:ok, :not_configured} when LINEAR_API_KEY is absent" do
      Application.delete_env(:guild, :linear_api_key)
      Application.delete_env(:guild, :linear_team_id)

      assert {:ok, :not_configured} = Linear.create_issue(%{title: "Test"})
    end

    test "returns {:ok, :not_configured} when LINEAR_TEAM_ID is absent" do
      Application.put_env(:guild, :linear_api_key, "lin_api_test")
      Application.delete_env(:guild, :linear_team_id)

      on_exit(fn ->
        Application.delete_env(:guild, :linear_api_key)
      end)

      assert {:ok, :not_configured} = Linear.create_issue(%{title: "Test"})
    end
  end

  describe "update_issue/2 — not configured" do
    test "returns {:ok, :not_configured} when credentials absent" do
      Application.delete_env(:guild, :linear_api_key)
      Application.delete_env(:guild, :linear_team_id)

      assert {:ok, :not_configured} = Linear.update_issue("issue-1", %{stateId: "state-1"})
    end
  end

  describe "create_issue/1 — with Bypass" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:guild, :linear_api_key, "lin_api_test_key")
      Application.put_env(:guild, :linear_team_id, "TEAM-123")
      Application.put_env(:guild, :linear_api_url, "http://localhost:#{bypass.port}/graphql")

      on_exit(fn ->
        Application.delete_env(:guild, :linear_api_key)
        Application.delete_env(:guild, :linear_team_id)
        Application.delete_env(:guild, :linear_api_url)
      end)

      {:ok, bypass: bypass}
    end

    test "sends GraphQL mutation with correct payload shape", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert Map.has_key?(decoded, "query")
        assert Map.has_key?(decoded, "variables")
        assert decoded["variables"]["teamId"] == "TEAM-123"
        assert decoded["variables"]["title"] == "Fix the bug"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            data: %{
              issueCreate: %{
                success: true,
                issue: %{id: "issue-abc", title: "Fix the bug"}
              }
            }
          })
        )
      end)

      assert {:ok, %{id: "issue-abc"}} =
               Linear.create_issue(%{title: "Fix the bug", description: "Details here"})
    end

    test "returns {:error, :permanent, :create_failed} when success is false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{data: %{issueCreate: %{success: false}}})
        )
      end)

      assert {:error, :permanent, :create_failed} = Linear.create_issue(%{title: "Test"})
    end

    test "returns {:error, :permanent, {:graphql_errors, _}} on GraphQL errors", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{errors: [%{message: "Unauthorized"}]})
        )
      end)

      assert {:error, :permanent, {:graphql_errors, _}} = Linear.create_issue(%{title: "Test"})
    end

    test "returns {:error, :transient, _} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        Plug.Conn.resp(conn, 500, "server error")
      end)

      assert {:error, :transient, {:http_error, 500}} = Linear.create_issue(%{title: "Test"})
    end
  end

  describe "update_issue/2 — with Bypass" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:guild, :linear_api_key, "lin_api_test_key")
      Application.put_env(:guild, :linear_team_id, "TEAM-123")
      Application.put_env(:guild, :linear_api_url, "http://localhost:#{bypass.port}/graphql")

      on_exit(fn ->
        Application.delete_env(:guild, :linear_api_key)
        Application.delete_env(:guild, :linear_team_id)
        Application.delete_env(:guild, :linear_api_url)
      end)

      {:ok, bypass: bypass}
    end

    test "sends GraphQL mutation with id and input variables", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert Map.has_key?(decoded, "query")
        assert Map.has_key?(decoded, "variables")
        assert decoded["variables"]["id"] == "issue-xyz"
        assert Map.has_key?(decoded["variables"], "input")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            data: %{
              issueUpdate: %{
                success: true,
                issue: %{id: "issue-xyz", title: "My Issue"}
              }
            }
          })
        )
      end)

      assert {:ok, %{id: "issue-xyz"}} =
               Linear.update_issue("issue-xyz", %{stateId: "in-progress-state-id"})
    end

    test "returns {:error, :permanent, :update_failed} when success is false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{data: %{issueUpdate: %{success: false}}})
        )
      end)

      assert {:error, :permanent, :update_failed} =
               Linear.update_issue("issue-xyz", %{stateId: "state-id"})
    end

    test "returns {:error, :transient, _} on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        Plug.Conn.resp(conn, 429, "rate limited")
      end)

      assert {:error, :transient, {:http_error, 429}} =
               Linear.update_issue("issue-xyz", %{stateId: "state-id"})
    end
  end
end
