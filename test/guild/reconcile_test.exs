defmodule Guild.ReconcileTest do
  use Guild.DataCase, async: false

  alias Guild.Repo
  alias Guild.Schema.{Thread, Artifact, Event}

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :fountain_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:guild, :fountain_api_key, "test_token")

    on_exit(fn ->
      Application.delete_env(:guild, :fountain_base_url)
      Application.delete_env(:guild, :fountain_api_key)
    end)

    {:ok, bypass: bypass}
  end

  defp insert_thread(state) do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{anchor_type: "github_issue", anchor_id: "3", state: state})
      |> Repo.insert()

    thread
  end

  defp insert_seed_event(thread_id) do
    Repo.insert!(%Event{
      source: "system",
      event_type: "issue_claimed",
      occurred_at: DateTime.utc_now(),
      raw_payload: %{},
      idempotency_key: "claim_seed:owner/test-repo:3",
      thread_id: thread_id
    })
  end

  defp insert_artifact(thread_id, type, opts \\ []) do
    {:ok, artifact} =
      %Artifact{}
      |> Artifact.changeset(%{
        thread_id: thread_id,
        artifact_type: type,
        source: Keyword.get(opts, :source, "test"),
        external_id: Keyword.get(opts, :external_id, "test-#{System.unique_integer()}"),
        url: Keyword.get(opts, :url, "https://example.com")
      })
      |> Repo.insert()

    artifact
  end

  describe "pass_a - executing → pr_open" do
    test "transitions to pr_open when Fountain idle and matching PR found", %{bypass: bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-test")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 42, "html_url" => "https://github.com/owner/test-repo/pull/42", "body" => "Closes #3"}
      ]})

      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-test", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "idle"}}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "pr_open"

      artifact = Repo.get_by(Artifact, thread_id: thread.id, artifact_type: "pull_request")
      assert artifact != nil
      assert artifact.external_id == "42"
    end

    test "no transition when Fountain is still running", %{bypass: bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-running")

      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-running", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "running"}}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "executing"
    end

    test "no transition when Fountain idle but no matching PR found", %{bypass: bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-no-pr")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 99, "html_url" => "https://github.com/owner/test-repo/pull/99", "body" => "Unrelated PR"}
      ]})

      Bypass.expect_once(bypass, "GET", "/api/conversations/conv-no-pr", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{status: "idle"}}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "executing"
    end
  end

  describe "pass_b - pr_open → done" do
    test "transitions to done when pull_request.merged event exists", %{bypass: bypass} do
      thread = insert_thread("pr_open")

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "42",
        url: "https://github.com/owner/test-repo/pull/42"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:42:#{System.unique_integer()}",
        thread_id: thread.id
      })

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "done"
    end
  end
end
