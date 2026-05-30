defmodule GuildWeb.ThreadLiveTest do
  use GuildWeb.ConnCase
  import Phoenix.LiveViewTest

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  setup do
    {:ok, thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_pr",
        anchor_id: "live-test-anchor-456",
        state: "executing"
      })
      |> Guild.Repo.insert()

    {:ok, thread: thread}
  end

  test "GET /threads/:id renders thread detail", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ thread.id
    assert html =~ "github_pr"
    assert html =~ "live-test-anchor-456"
    assert html =~ "executing"
  end

  test "GET /threads/:id renders merged timeline section", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "Timeline"
  end

  test "GET /threads/:id shows owner info card", %{conn: conn, thread: thread} do
    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "Owner"
    assert html =~ "Created"
    assert html =~ "Updated"
  end

  test "GET /threads/:id shows timeline entries for decisions with snapshot trimmed indicator",
       %{conn: conn, thread: thread} do
    # Insert a decision with no context_snapshot
    {:ok, _} =
      %Guild.Schema.DecisionsLog{}
      |> Guild.Schema.DecisionsLog.changeset(%{
        thread_id: thread.id,
        decision_type: "plan",
        reasoning: "test reasoning without snapshot"
      })
      |> Guild.Repo.insert()

    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    assert html =~ "snapshot trimmed"
  end

  test "GET /threads/:id does NOT show snapshot trimmed when snapshot present",
       %{conn: conn, thread: thread} do
    # Insert a decision with a context_snapshot
    {:ok, _} =
      %Guild.Schema.DecisionsLog{}
      |> Guild.Schema.DecisionsLog.changeset(%{
        thread_id: thread.id,
        decision_type: "claim",
        reasoning: "reasoning with snapshot",
        context_snapshot: %{"key" => "value"}
      })
      |> Guild.Repo.insert()

    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
    refute html =~ "snapshot trimmed"
  end

  test "unauthenticated live mount is rejected", %{conn: conn, thread: thread} do
    # Without auth headers the :auth pipeline halts with 401.
    # The halted conn (no static token) causes LiveViewTest to raise.
    assert_raise FunctionClauseError, fn ->
      live(conn, ~p"/threads/#{thread.id}")
    end
  end

  describe "thread action buttons" do
    setup do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-uuid",
        vault_id: "vault-uuid"
      })
      on_exit(fn ->
        Guild.Repo.delete_all(Guild.Schema.Thread)
        Guild.Repo.delete_all(Guild.Schema.Worker)
      end)
      :ok
    end

    test "executing non-held thread shows Hold and Abandon, no Resume", %{conn: conn} do
      thread = Guild.Repo.insert!(%Guild.Schema.Thread{
        anchor_type: "github_issue", anchor_id: "100",
        state: "executing", held: false
      })
      {:ok, _view, html} = live(conn |> with_auth(), ~p"/threads/#{thread.id}")
      assert html =~ "Hold"
      assert html =~ "Abandon"
      refute html =~ "Resume"
    end

    test "held thread shows Resume, no Hold", %{conn: conn} do
      thread = Guild.Repo.insert!(%Guild.Schema.Thread{
        anchor_type: "github_issue", anchor_id: "101",
        state: "executing", held: true
      })
      {:ok, _view, html} = live(conn |> with_auth(), ~p"/threads/#{thread.id}")
      assert html =~ "Resume"
      refute html =~ ">Hold<"
    end

    test "done thread shows no action buttons", %{conn: conn} do
      thread = Guild.Repo.insert!(%Guild.Schema.Thread{
        anchor_type: "github_issue", anchor_id: "102",
        state: "done", held: false
      })
      {:ok, _view, html} = live(conn |> with_auth(), ~p"/threads/#{thread.id}")
      refute html =~ "thread-actions"
    end
  end

  test "GET /threads/:id shows stuck warning banner for over-threshold executing thread",
       %{conn: conn} do
    {:ok, stuck_thread} =
      %Guild.Schema.Thread{}
      |> Guild.Schema.Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "stuck-show-1",
        state: "executing"
      })
      |> Guild.Repo.insert()

    # Set updated_at to 3 hours ago (exceeds 2-hour executing threshold)
    past = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
    import Ecto.Query
    Guild.Repo.update_all(
      from(t in Guild.Schema.Thread, where: t.id == ^stuck_thread.id),
      set: [updated_at: past]
    )

    {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{stuck_thread.id}")
    assert html =~ "stuck"
    assert html =~ "Warning"
  end
end
