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

  defp insert_thread_with_id(anchor_id, state, opts \\ []) do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(
        %{anchor_type: "github_issue", anchor_id: anchor_id, state: state}
        |> Map.merge(Map.new(opts))
      )
      |> Repo.insert()

    thread
  end

  describe "pass_a Slack blocks — executing → pr_open" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()

      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{slack_bypass.port}/api/chat.postMessage")

      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)

      {:ok, slack_bypass: slack_bypass}
    end

    test "pass A Slack message includes guild_hold and guild_abandon action_ids", %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-blocks-a")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 55, "html_url" => "https://github.com/owner/test-repo/pull/55", "body" => "Closes #3"}
      ]})

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      assert msg != nil
      assert is_list(msg["blocks"])

      action_ids =
        msg["blocks"]
        |> Enum.filter(&(&1["type"] == "actions"))
        |> Enum.flat_map(& &1["elements"])
        |> Enum.map(& &1["action_id"])

      assert "guild_hold" in action_ids
      assert "guild_abandon" in action_ids
    end

    test "pass A creates slack_message artifact with correct url when Slack returns channel+ts", %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-artifact-a")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 56, "html_url" => "https://github.com/owner/test-repo/pull/56", "body" => "Closes #3"}
      ]})

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C_TEST", ts: "1111111111.000001"}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      artifact =
        Repo.one(
          from a in Artifact,
            where: a.thread_id == ^thread.id and a.artifact_type == "slack_message"
        )

      assert artifact != nil
      assert artifact.source == "slack"
      assert artifact.external_id == "1111111111.000001"
      assert artifact.url == "slack://C_TEST/1111111111.000001"
    end

    test "pass A skips slack_message artifact when Slack returns no channel/ts", %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-no-ts-a")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 57, "html_url" => "https://github.com/owner/test-repo/pull/57", "body" => "Closes #3"}
      ]})

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      count =
        Repo.aggregate(
          from(a in Artifact, where: a.thread_id == ^thread.id and a.artifact_type == "slack_message"),
          :count,
          :id
        )

      assert count == 0
    end
  end

  describe "pass_b Slack blocks — pr_open → done" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()

      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{slack_bypass.port}/api/chat.postMessage")

      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)

      {:ok, slack_bypass: slack_bypass}
    end

    test "pass B Slack message includes guild_view action_id", %{slack_bypass: slack_bypass} do
      thread = insert_thread("pr_open")

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "88",
        url: "https://github.com/owner/test-repo/pull/88"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:88:#{System.unique_integer()}",
        thread_id: thread.id
      })

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      assert msg != nil
      assert is_list(msg["blocks"])

      action_ids =
        msg["blocks"]
        |> Enum.filter(&(&1["type"] == "actions"))
        |> Enum.flat_map(& &1["elements"])
        |> Enum.map(& &1["action_id"])

      assert "guild_view" in action_ids
    end

    test "pass B creates slack_message artifact with correct url when Slack returns channel+ts", %{slack_bypass: slack_bypass} do
      thread = insert_thread("pr_open")

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "89",
        url: "https://github.com/owner/test-repo/pull/89"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:89:#{System.unique_integer()}",
        thread_id: thread.id
      })

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C_TEST", ts: "2222222222.000002"}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      artifact =
        Repo.one(
          from a in Artifact,
            where: a.thread_id == ^thread.id and a.artifact_type == "slack_message"
        )

      assert artifact != nil
      assert artifact.source == "slack"
      assert artifact.external_id == "2222222222.000002"
      assert artifact.url == "slack://C_TEST/2222222222.000002"
    end

    test "pass B slack_message artifact insertion is idempotent (on_conflict: :nothing)", %{slack_bypass: slack_bypass} do
      thread = insert_thread("pr_open")

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "90",
        url: "https://github.com/owner/test-repo/pull/90"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:90:#{System.unique_integer()}",
        thread_id: thread.id
      })

      # Pre-insert the artifact to simulate a duplicate
      {:ok, _} =
        %Artifact{}
        |> Artifact.changeset(%{
          thread_id: thread.id,
          artifact_type: "slack_message",
          source: "slack",
          external_id: "3333333333.000003",
          url: "slack://C_TEST/3333333333.000003"
        })
        |> Repo.insert()

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C_TEST", ts: "3333333333.000003"}))
      end)

      # Should not raise — on_conflict: :nothing handles the duplicate
      :ok = Guild.Reconcile.reconcile_all()

      count =
        Repo.aggregate(
          from(a in Artifact, where: a.thread_id == ^thread.id and a.artifact_type == "slack_message"),
          :count,
          :id
        )

      assert count == 1
    end
  end

  describe "held thread skipping — pass A" do
    test "pass A skips executing threads with held = true", %{bypass: _bypass} do
      thread = insert_thread_with_id("held-issue-1", "executing")
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-held")
      Repo.update!(Thread.changeset(thread, %{held: true}))

      # This PR would normally trigger a transition — but thread is held.
      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 10, "html_url" => "https://github.com/owner/repo/pull/10", "body" => "Closes #held-issue-1"}
      ]})

      :ok = Guild.Reconcile.reconcile_all()

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "executing"
    end
  end

  describe "held thread skipping — pass C" do
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

    test "pass C does not alert on held threads even if they are stuck", %{slack_bypass: slack_bypass} do
      thread = insert_thread_with_id("held-issue-2", "executing")
      Repo.update!(Thread.changeset(thread, %{held: true}))

      # Set updated_at to 3 hours ago (exceeds 2-hour executing threshold)
      past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      Repo.update_all(from(t in Thread, where: t.id == ^thread.id), set: [updated_at: past])

      Bypass.stub(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        flunk("Pass C should not alert on a held thread")
        Plug.Conn.resp(conn, 200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()
    end
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

    test "self-heals executing → done in one reconcile when a matching merged PR + merged event exist",
         %{bypass: bypass} do
      # Reproduces the live scenario: a PR was opened and merged before reconcile
      # observed it open. The merged event is already ingested; Pass A promotes to
      # pr_open (matching the merged PR via state: "all") and Pass B finishes it.
      # Pass D then runs and calls get_status on the fountain_conversation artifact.
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

      # Pass D will call get_status and then terminate_conversation for the now-done thread
      Bypass.stub(bypass, "GET", "/api/conversations/conv-merged", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"id" => "conv-merged", "status" => "running"}}))
      end)

      Bypass.stub(bypass, "POST", "/api/conversations/conv-merged/terminate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"id" => "conv-merged"}}))
      end)

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

  describe "pass_a — stores slack_thread_ts anchor on thread" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()
      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{slack_bypass.port}/api/chat.postMessage")
      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)
      {:ok, slack_bypass: slack_bypass}
    end

    test "stores slack_channel and slack_thread_ts on thread after first pr_open post",
         %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-anchor-a")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 60, "html_url" => "https://github.com/owner/test-repo/pull/60", "body" => "Closes #3"}
      ]})

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C123", ts: "111.222"}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      updated = Repo.get!(Thread, thread.id)
      assert updated.slack_channel == "C123"
      assert updated.slack_thread_ts == "111.222"
    end

    test "pass A does NOT send thread_ts in post_message payload (it is the anchor)",
         %{slack_bypass: slack_bypass} do
      thread = insert_thread("executing")
      insert_seed_event(thread.id)
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: "conv-anchor-b")

      Guild.GitHub.TestAdapter.configure(:list_pull_requests, {:ok, [
        %{"number" => 61, "html_url" => "https://github.com/owner/test-repo/pull/61", "body" => "Closes #3"}
      ]})

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true, channel: "C123", ts: "111.333"}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      refute Map.has_key?(msg, "thread_ts")
    end
  end

  describe "pass_b — thread_ts threading" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()
      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{slack_bypass.port}/api/chat.postMessage")
      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)
      {:ok, slack_bypass: slack_bypass}
    end

    test "pass B sends thread_ts in payload when thread has slack_thread_ts",
         %{slack_bypass: slack_bypass} do
      thread =
        %Thread{}
        |> Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "200",
          state: "pr_open",
          slack_channel: "C123",
          slack_thread_ts: "111.222"
        })
        |> Repo.insert!()

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "200",
        url: "https://github.com/owner/test-repo/pull/200"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:200:#{System.unique_integer()}",
        thread_id: thread.id
      })

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      assert msg["thread_ts"] == "111.222"
    end

    test "pass B does NOT send thread_ts when thread.slack_thread_ts is nil (fallback top-level)",
         %{slack_bypass: slack_bypass} do
      thread = insert_thread("pr_open")

      insert_artifact(thread.id, "pull_request",
        source: "github",
        external_id: "201",
        url: "https://github.com/owner/test-repo/pull/201"
      )

      Repo.insert!(%Event{
        source: "github",
        event_type: "pull_request.merged",
        occurred_at: DateTime.utc_now(),
        raw_payload: %{"action" => "closed", "pull_request" => %{"merged" => true}},
        idempotency_key: "pr_merged:201:#{System.unique_integer()}",
        thread_id: thread.id
      })

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      refute Map.has_key?(msg, "thread_ts")
    end
  end

  describe "pass_c — thread_ts threading for stuck alerts" do
    setup %{bypass: _fountain_bypass} do
      slack_bypass = Bypass.open()
      Application.put_env(:guild, :slack_bot_token, "xoxb-test")
      Application.put_env(:guild, :slack_channel_id, "C_TEST")
      Application.put_env(:guild, :slack_api_url, "http://localhost:#{slack_bypass.port}/api/chat.postMessage")
      on_exit(fn ->
        Application.delete_env(:guild, :slack_bot_token)
        Application.delete_env(:guild, :slack_channel_id)
        Application.delete_env(:guild, :slack_api_url)
      end)
      {:ok, slack_bypass: slack_bypass}
    end

    test "pass C sends thread_ts in Slack payload when thread has slack_thread_ts",
         %{slack_bypass: slack_bypass} do
      thread =
        %Thread{}
        |> Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "stuck-300",
          state: "executing",
          slack_channel: "C123",
          slack_thread_ts: "999.111"
        })
        |> Repo.insert!()

      past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      Repo.update_all(from(t in Thread, where: t.id == ^thread.id), set: [updated_at: past])

      received = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(slack_bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received, fn _ -> decoded end)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      msg = Agent.get(received, & &1)
      assert msg["thread_ts"] == "999.111"
    end
  end

  describe "pass_d - terminate Fountain conversations for done/abandoned threads" do
    test "terminates an active conversation for a done thread", %{bypass: bypass} do
      thread = insert_thread("done")
      conv_id = "conv-active-#{System.unique_integer([:positive])}"
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: conv_id)

      Bypass.expect_once(bypass, "GET", "/api/conversations/#{conv_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"id" => conv_id, "status" => "running"}}))
      end)

      Bypass.expect_once(bypass, "POST", "/api/conversations/#{conv_id}/terminate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"id" => conv_id}}))
      end)

      :ok = Guild.Reconcile.reconcile_all()

      # Pass D should flip terminated: true on the artifact so it is not re-checked.
      art = Repo.get_by(Artifact, thread_id: thread.id, artifact_type: "fountain_conversation")
      assert art.terminated == true
    end

    test "skips entirely when artifact.terminated is already true" do
      thread = insert_thread("done")
      conv_id = "conv-flagged-#{System.unique_integer([:positive])}"
      art = insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: conv_id)
      Repo.update!(Artifact.changeset(art, %{terminated: true}))

      # No Bypass expectations set: any HTTP call to Fountain would 502 from Bypass
      # and surface as an error in logs. reconcile_all should make zero Fountain calls.
      :ok = Guild.Reconcile.reconcile_all()
    end

    test "skips termination when conversation is already terminated (idempotent)", %{bypass: bypass} do
      thread = insert_thread("done")
      conv_id = "conv-done-#{System.unique_integer([:positive])}"
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: conv_id)

      Bypass.expect_once(bypass, "GET", "/api/conversations/#{conv_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"id" => conv_id, "status" => "terminated"}}))
      end)

      # terminate endpoint must NOT be called — verify by failing if it is
      Bypass.stub(bypass, "POST", "/api/conversations/#{conv_id}/terminate", fn _conn ->
        flunk("terminate should not be called for an already-terminated conversation")
      end)

      :ok = Guild.Reconcile.reconcile_all()
    end

    test "logs warning on Fountain error and does not crash reconcile", %{bypass: bypass} do
      thread = insert_thread("done")
      conv_id = "conv-err-#{System.unique_integer([:positive])}"
      insert_artifact(thread.id, "fountain_conversation", source: "fountain", external_id: conv_id)

      Bypass.expect_once(bypass, "GET", "/api/conversations/#{conv_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal server error"}))
      end)

      # reconcile_all must return :ok despite the Fountain error
      :ok = Guild.Reconcile.reconcile_all()
    end
  end
end
