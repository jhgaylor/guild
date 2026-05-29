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
    test "transitions to pr_open when a matching PR exists, regardless of worker conv status" do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-test")

      # No Fountain status mock: reconcile must NOT call get_status. The worker
      # conv legitimately stays alive after opening its PR, so the PR's
      # existence — not conv status — drives the transition.
      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 42, "html_url" => "https://github.com/owner/test-repo/pull/42", "body" => "Closes #3"}
      ]})

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "pr_open"

      artifact = Repo.get_by(Artifact, thread_id: thread.id, artifact_type: "pull_request")
      assert artifact != nil
      assert artifact.external_id == "42"
    end

    test "self-heals executing → done in one reconcile when a matching merged PR + merged event exist" do
      # Reproduces the live scenario: a PR was opened and merged before reconcile
      # observed it open. The merged event is already ingested; Pass A promotes to
      # pr_open (matching the merged PR via state: \"all\") and Pass B finishes it.
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-merged")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 35, "html_url" => "https://github.com/owner/test-repo/pull/35", "body" => "Closes #3"}
      ]})

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:35:#{System.unique_integer()}",
        thread_id: thread.id
      })

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "done"
    end

    test "no transition when no matching PR found" do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-no-pr")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 99, "html_url" => "https://github.com/owner/test-repo/pull/99", "body" => "Unrelated PR"}
      ]})

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

  describe "pass_b - owner release on done" do
    test "clears owner when thread transitions to done" do
      thread =
        %Thread{}
        |> Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "99",
          state: "pr_open",
          owner: "worker-agent-1"
        })
        |> Repo.insert!()

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "77",
        url: "https://github.com/owner/test-repo/pull/77"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:77:#{System.unique_integer()}",
        thread_id: thread.id
      })

      :ok = Guild.Reconcile.reconcile_all()

      thread = Repo.get!(Thread, thread.id)
      assert thread.state == "done"
      assert thread.owner == nil
    end
  end

  describe "pass_c - stuck thread alerting" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()

      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")

      Application.put_env(
        :guild,
        :slack_api_url,
        "http://localhost:#{slack_bypass.port}/api/chat.postMessage"
      )

      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)

      {:ok, slack_bypass: slack_bypass}
    end

    test "posts Slack alert and sets last_alerted_at for over-threshold :executing thread",
         %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")

      # Set updated_at to 3 hours ago (exceeds 2-hour executing threshold)
      past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      Repo.update_all(from(t in Thread, where: t.id == ^thread.id), set: [updated_at: past])

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["text"] =~ thread.id
        assert decoded["text"] =~ "stuck"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      updated = Repo.get!(Thread, thread.id)
      assert updated.last_alerted_at != nil
    end

    test "skips re-alert when last_alerted_at is within cooldown", %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")

      # 3 hours ago — exceeds threshold
      past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      # 1 hour ago — within 6-hour cooldown
      one_hour_ago = DateTime.add(DateTime.utc_now(), -1 * 3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(t in Thread, where: t.id == ^thread.id),
        set: [updated_at: past, last_alerted_at: one_hour_ago]
      )

      # Pass C must not call Slack at all — thread is filtered by cooldown query
      Bypass.stub(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        flunk("Slack should not be called during cooldown period")
        Plug.Conn.resp(conn, 200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      updated = Repo.get!(Thread, thread.id)
      # last_alerted_at should still equal one_hour_ago (not updated)
      assert DateTime.diff(updated.last_alerted_at, one_hour_ago, :second) == 0
    end
  end
end
