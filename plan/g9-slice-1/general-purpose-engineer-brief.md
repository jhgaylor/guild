# G9 Slice 1 — Outbound Thread Continuity

Repo: jhgaylor/guild. Branch: g9/slice-1-outbound-threading.
TESTS REQUIRED. Read existing reconcile.ex + slack adapter before editing.
Do NOT create scratch docs outside plan/g9-slice-1/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

## 1. Migration — priv/repo/migrations/20260530011517_add_slack_thread_to_threads.exs

Add to threads table:
  add :slack_thread_ts, :string, null: true
  add :slack_channel, :string, null: true

Add composite index:
  create index(:threads, [:slack_channel, :slack_thread_ts])

Backfill in the up/0 migration (after alter table):
  Query all threads that have a slack_message Artifact (artifact_type == "slack_message",
  url starts with "slack://") but have slack_thread_ts IS NULL.
  For each, parse the earliest such artifact's url: "slack://channel/ts" → split on "/"
  after stripping "slack://", channel = first part, ts = second part.
  Update thread: set slack_channel = channel, slack_thread_ts = ts.

## 2. Schema — lib/guild/schema/thread.ex

Current fields (from the file):
  field :anchor_type, :string
  field :anchor_id, :string
  field :anchor_url, :string
  field :state, :string
  field :owner, :string
  field :parent_thread_id, :binary_id
  field :linear_issue_id, :string
  field :last_alerted_at, :utc_datetime
  field :held, :boolean, default: false
  field :state_entered_at, :utc_datetime_usec

Add:
  field :slack_thread_ts, :string
  field :slack_channel, :string

Update changeset to cast these fields (add them to the existing cast/2 list alongside the others).

## 3. Adapter — lib/guild/adapters/slack.ex

Current signature: `def post_message(channel \\ nil, text, opts \\ [])`

Extend `maybe_put_blocks/2` pattern with a new private function `maybe_put_thread_ts/2`:
  When opts[:thread_ts] is present and non-nil, add "thread_ts" => opts[:thread_ts]
  to the chat.postMessage JSON payload (alongside channel, text, blocks).
  Return value {:ok, %{channel: c, ts: ts}} stays unchanged.
  Graceful no-op when unconfigured stays unchanged.

The payload build chain should become:
  %{channel: channel, text: text}
  |> maybe_put_blocks(opts)
  |> maybe_put_thread_ts(opts)

## 4. Reconcile Pass A — `promote_to_pr_open/2` in lib/guild/reconcile.ex

Location: the `promote_to_pr_open(thread, pr)` private function.
After successful post_message returns {:ok, %{channel: c, ts: ts}} when not is_nil(c) and not is_nil(ts):

EXISTING behavior (keep): insert slack_message Artifact with url "slack://#{c}/#{ts}".

ADD after the artifact insert (or wrap it): if thread.slack_thread_ts is nil:
  Guild.Repo.update(Ecto.Changeset.change(thread, slack_channel: c, slack_thread_ts: ts))

Do NOT pass thread_ts in the post_message opts for this call (it IS the top-level anchor post).

Full updated match arm:
  {:ok, %{channel: c, ts: ts}} when not is_nil(c) and not is_nil(ts) ->
    slack_url = "slack://" <> c <> "/" <> ts
    # insert slack_message artifact (existing code, unchanged)
    ...
    # NEW: store anchor on thread if not already set
    if is_nil(thread.slack_thread_ts) do
      Guild.Repo.update(Ecto.Changeset.change(thread, slack_channel: c, slack_thread_ts: ts))
    end

## 5. Reconcile Pass B — `reconcile_pr_open_thread/2` in lib/guild/reconcile.ex

Location: the `reconcile_pr_open_thread(thread, artifact)` private function.
The :done transition's post_message call (for the `:done` notification) currently passes no thread_ts.

CHANGE the post_message call to pass thread_ts when the thread has one:

  thread_ts_opt = if thread.slack_thread_ts, do: [thread_ts: thread.slack_thread_ts], else: []

  case Guild.Adapters.Slack.post_message(
         nil,
         "Thread ##{thread.id}: :done",
         Keyword.merge([blocks: blocks], thread_ts_opt)
       ) do

(When slack_thread_ts is nil, thread_ts_opt is [], so post_message behaves exactly as before — top-level post.)

## 6. Reconcile Pass C — `pass_c/0` in lib/guild/reconcile.ex

Location: the anonymous Enum.each block inside `pass_c/0` that calls `Guild.Adapters.Slack.post_message`.

Current call (single-arg form): `Guild.Adapters.Slack.post_message("Thread ##{thread.id} appears stuck: ...")`

CHANGE to pass thread_ts when set:

  thread_ts_opt = if thread.slack_thread_ts, do: [thread_ts: thread.slack_thread_ts], else: []

  Guild.Adapters.Slack.post_message(
    nil,
    "Thread ##{thread.id} appears stuck: state=#{thread.state}, age=#{age_hours}h",
    thread_ts_opt
  )

(When nil, thread_ts_opt is [] so it behaves as before — top-level post. Use nil for channel so it falls back to default_channel().)

## 7. Tests

### test/guild/adapters/slack_test.exs

Add to the existing `"post_message/2 — with Bypass"` describe block:

```elixir
test "includes thread_ts in payload when opts[:thread_ts] is given", %{bypass: bypass} do
  Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    decoded = Jason.decode!(body)
    assert decoded["thread_ts"] == "1234.5678"
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
  end)

  assert {:ok, _} = Slack.post_message("C123", "reply text", thread_ts: "1234.5678")
end

test "omits thread_ts key when not given in opts", %{bypass: bypass} do
  Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    decoded = Jason.decode!(body)
    refute Map.has_key?(decoded, "thread_ts")
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
  end)

  assert {:ok, _} = Slack.post_message("C123", "top level text")
end
```

### test/guild/reconcile_test.exs

Add a new describe block (e.g. after the existing `"pass_a Slack blocks"` block):

```elixir
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
```

## Implementation Notes

- The next migration timestamp to use is `20260530011517` (the last migration is `20260530011516_add_state_entered_at_to_threads.exs`).
- Pass A's `promote_to_pr_open/2` is called from `check_for_pr/1` → `reconcile_executing_thread/2`.
- Pass B's `reconcile_pr_open_thread/2` is also called directly from `reconcile_thread/1` for the `:pr_open` state.
- Pass C's stuck alert is inline in `pass_c/0` — the single-arg `post_message` call needs to become a three-arg call with `nil` channel and opts.
- The `maybe_put_thread_ts/2` helper in the Slack adapter follows the same pattern as `maybe_put_blocks/2`.
- Artifact url format is already `"slack://channel/ts"` (established in G6 Slice 2).
- The backfill in the migration is defensive; in prod the data set is zero rows with slack_message artifacts (Slack was not live), but the migration is correct for upgrade story.
