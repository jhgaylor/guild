# G10 Slice 1 — Routing + Listening Foundation

Repo: jhgaylor/guild. Branch: g10/slice-1-routing-foundation.
Base off: `main` (b53583b).
TESTS REQUIRED. Read existing files before editing. No scratch docs outside plan/g10-slice-1/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

The goal: give the operator a config surface for which Slack channels Guild listens in, and gate the Events handler so it short-circuits for un-configured or disabled channels. No classifier yet — that's Slice 2. This slice only adds the plumbing.

---

## 1. Migration — `priv/repo/migrations/20260531100001_create_slack_channels.exs`

```elixir
defmodule Guild.Repo.Migrations.CreateSlackChannels do
  use Ecto.Migration

  def change do
    create table(:slack_channels, primary_key: false) do
      add :channel_id, :string, primary_key: true
      add :default_repo, :string, null: true  # FK-like reference to repos.full_name; nullable
      add :enabled, :boolean, null: false, default: true
      add :notes, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # No foreign key constraint — repos table uses a string PK; keep it loose.
    create index(:slack_channels, [:enabled])
  end
end
```

Use `change` (not `up/down`) — straightforward table creation.

---

## 2. Schema — `lib/guild/schema/slack_channel.ex`

New file. Pattern matches `lib/guild/schema/repo.ex`:

```elixir
defmodule Guild.Schema.SlackChannel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:channel_id, :string, autogenerate: false}

  schema "slack_channels" do
    field :default_repo, :string          # nullable; references repos.full_name
    field :enabled, :boolean, default: true
    field :notes, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(slack_channel, attrs) do
    slack_channel
    |> cast(attrs, [:channel_id, :default_repo, :enabled, :notes])
    |> validate_required([:channel_id])
    |> unique_constraint(:channel_id, name: :slack_channels_pkey)
  end
end
```

Notes:
- No `belongs_to` — the `default_repo` is a plain string FK kept loose intentionally.
- `notes` uses `:string` (maps to `:text` column fine via Ecto).

---

## 3. Admin CRUD — `lib/guild_web/controllers/admin_controller.ex`

Add four new action functions after the existing `integrations/2` action. Pattern closely follows `repos/2`, `create_repo/2`, `toggle_repo/2`, `disable_repo/2`.

```elixir
def slack_channels(conn, _params) do
  channels = Guild.Repo.all(Guild.Schema.SlackChannel)
  repos = Guild.Repo.all(Guild.Schema.Repo)
  changeset = Ecto.Changeset.change(%Guild.Schema.SlackChannel{})
  render(conn, :slack_channels, channels: channels, repos: repos, changeset: changeset)
end

def create_slack_channel(conn, params) do
  channel_id = String.trim(params["channel_id"] || "")
  default_repo = case String.trim(params["default_repo"] || "") do
    "" -> nil
    v  -> v
  end

  if channel_id == "" do
    channels = Guild.Repo.all(Guild.Schema.SlackChannel)
    repos = Guild.Repo.all(Guild.Schema.Repo)
    changeset =
      Guild.Schema.SlackChannel.changeset(%Guild.Schema.SlackChannel{}, %{channel_id: ""})
      |> Ecto.Changeset.add_error(:channel_id, "can't be blank")
      |> Map.put(:action, :insert)
    conn
    |> put_status(200)
    |> render(:slack_channels, channels: channels, repos: repos, changeset: changeset)
  else
    attrs = %{
      channel_id: channel_id,
      default_repo: default_repo,
      enabled: true,
      notes: String.trim(params["notes"] || "")
    }
    changeset = Guild.Schema.SlackChannel.changeset(%Guild.Schema.SlackChannel{}, attrs)
    Guild.Repo.insert(changeset, on_conflict: :nothing, conflict_target: :channel_id)
    redirect(conn, to: ~p"/admin/slack-channels")
  end
end

def toggle_slack_channel(conn, %{"channel_id" => channel_id}) do
  channel = Guild.Repo.get!(Guild.Schema.SlackChannel, channel_id)
  changeset = Ecto.Changeset.change(channel, enabled: !channel.enabled)
  Guild.Repo.update!(changeset)
  redirect(conn, to: ~p"/admin/slack-channels")
end

def delete_slack_channel(conn, %{"channel_id" => channel_id}) do
  channel = Guild.Repo.get!(Guild.Schema.SlackChannel, channel_id)
  Guild.Repo.delete!(channel)
  redirect(conn, to: ~p"/admin/slack-channels")
end
```

---

## 4. Template — `lib/guild_web/controllers/admin_html/slack_channels.html.heex`

New file. Pattern matches `repos.html.heex`:

```html
<div class="container">
  <h1 class="page-title">Slack Channels</h1>
  <p class="page-subtitle"><a href={~p"/admin"}>← Admin</a></p>

  <%= if Enum.empty?(@channels) do %>
    <p class="empty-state">No Slack channels configured yet.</p>
  <% else %>
    <table class="data-table">
      <thead>
        <tr>
          <th>Channel ID</th>
          <th>Status</th>
          <th>Default Repo</th>
          <th>Notes</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <%= for ch <- @channels do %>
          <tr>
            <td><code><%= ch.channel_id %></code></td>
            <td>
              <%= if ch.enabled do %>
                <span class="badge badge--green">enabled</span>
              <% else %>
                <span class="badge badge--red">disabled</span>
              <% end %>
            </td>
            <td><%= ch.default_repo || "—" %></td>
            <td><%= ch.notes || "—" %></td>
            <td>
              <form method="post" action={~p"/admin/slack-channels/#{ch.channel_id}/toggle"} style="display:inline">
                <input type="hidden" name="_method" value="patch" />
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <button type="submit"><%= if ch.enabled, do: "Disable", else: "Enable" %></button>
              </form>
              <form method="post" action={~p"/admin/slack-channels/#{ch.channel_id}"} style="display:inline">
                <input type="hidden" name="_method" value="delete" />
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <button type="submit">Delete</button>
              </form>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>

  <h2>Add Channel</h2>
  <.form :let={f} for={@changeset} action={~p"/admin/slack-channels"} method="post">
    <.input field={f[:channel_id]} label="Channel ID (e.g. C012AB3CD)" required />
    <div>
      <label for="default_repo">Default Repo (optional)</label>
      <select name="default_repo" id="default_repo">
        <option value="">— none —</option>
        <%= for repo <- @repos do %>
          <option value={repo.full_name}><%= repo.full_name %></option>
        <% end %>
      </select>
    </div>
    <.input field={f[:notes]} label="Notes (optional)" />
    <button type="submit">Add Channel</button>
  </.form>
</div>
```

---

## 5. Router — `lib/guild_web/router.ex`

Inside the existing `scope "/admin"` block (the one behind `:browser, :auth`), add four routes after the existing `integrations` route:

```elixir
get "/slack-channels", AdminController, :slack_channels
post "/slack-channels", AdminController, :create_slack_channel
patch "/slack-channels/:channel_id/toggle", AdminController, :toggle_slack_channel
delete "/slack-channels/:channel_id", AdminController, :delete_slack_channel
```

Note: `channel_id` is a plain Slack channel ID like `C012AB3CD` — no URL encoding needed (no slashes).

---

## 6. Admin index card — `lib/guild_web/controllers/admin_html/index.html.heex`

Add a fourth card to the `admin-cards` div, after the Integrations card:

```html
<a href={~p"/admin/slack-channels"} class="admin-card">
  <h2>Slack Channels</h2>
  <p>Configure which Slack channels Guild listens in and where new work is filed.</p>
</a>
```

---

## 7. Events handler gate — `lib/guild_web/controllers/slack_controller.ex`

The gate applies to top-level messages only (no `thread_ts`). Find the `dispatch_event/2` clause that handles `"event_callback"` events. This is the clause around line 100 of the current file that matches `%{"type" => "event_callback", "event" => event}`.

Within that clause, after computing `thread_id` and calling `record_slack_event/3`, add a gate before the existing `case event do` state-driving block. The gate runs only for top-level message events:

```elixir
# Gate: for top-level messages in enabled slack_channels, enqueue SlackInboxWorker (Slice 2).
# For now (Slice 1): just audit-only — the worker doesn't exist yet; the gate short-circuits.
case event do
  %{"type" => "message", "channel" => ch_id} when not is_map_key(event, "thread_ts") ->
    case Guild.Repo.get(Guild.Schema.SlackChannel, ch_id) do
      %Guild.Schema.SlackChannel{enabled: true} ->
        # Slice 2 will enqueue SlackInboxWorker here.
        # For now: channel is configured and enabled; fall through to state-driving.
        :ok

      _ ->
        # Not configured or disabled: audit-only (event row already recorded above).
        # Return early — skip state-driving.
        nil
    end

  _ ->
    # Not a top-level message event; continue to state-driving as before.
    :ok
end
```

**Implementation note:** The existing `case event do` state-driving block only cares about `reaction_added` events. For messages, it already falls through to the catch-all `_ -> :ok`. So the gate can be placed as a guard that still allows reaction events through. The cleanest approach:

Replace the existing block structure (state-driving `case`) by first checking if it's a gated top-level message, and if the channel is not enabled, return early (the `send_resp` is already called later; you need to avoid the function falling off). 

**Exact edit:** In the `dispatch_event(conn, %{"type" => "event_callback", "event" => event} = params)` clause, after `record_slack_event(event_type, params, thread_id)` and before the `case event do` state-driving block, insert:

```elixir
# Slice 1 gate: top-level messages only flow through if channel is enabled.
# Slice 2 will enqueue SlackInboxWorker in the :ok branch.
should_process =
  case event do
    %{"type" => "message", "channel" => ch_id} when not is_map_key(event, "thread_ts") ->
      case Guild.Repo.get(Guild.Schema.SlackChannel, ch_id) do
        %Guild.Schema.SlackChannel{enabled: true} -> true
        _ -> false
      end
    _ ->
      true
  end

if should_process do
  # existing state-driving case event do ... end
  case event do
    %{"type" => "reaction_added", ...} -> ...
    _ -> :ok
  end
end
```

The `send_resp(conn, 200, "")` at the end of the clause is unconditional — keep it that way. The gate only controls whether the state-driving block runs.

Read the actual current code in `lib/guild_web/controllers/slack_controller.ex` before editing. The above is pseudocode describing intent; fit it to the actual structure you see.

---

## 8. Tests — `test/guild_web/controllers/admin_controller_test.exs`

Add a new `describe` block for Slack Channels. Place it after the existing `/admin/integrations` describe block. Pattern: same `with_auth/1` helper already in that file.

```elixir
describe "GET /admin/slack-channels" do
  test "without auth returns 401", %{conn: conn} do
    conn = get(conn, ~p"/admin/slack-channels")
    assert conn.status == 401
  end

  test "with auth returns 200", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/admin/slack-channels")
    assert html_response(conn, 200) =~ "Slack Channels"
  end

  test "lists existing channels", %{conn: conn} do
    {:ok, _} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C111TEST"})
    conn = conn |> with_auth() |> get(~p"/admin/slack-channels")
    assert html_response(conn, 200) =~ "C111TEST"
  end
end

describe "POST /admin/slack-channels" do
  test "creates a channel and redirects", %{conn: conn} do
    conn =
      conn
      |> with_auth()
      |> post(~p"/admin/slack-channels", %{channel_id: "C222TEST", default_repo: "", notes: ""})
    assert redirected_to(conn) == ~p"/admin/slack-channels"
    assert Guild.Repo.get(Guild.Schema.SlackChannel, "C222TEST") != nil
  end

  test "blank channel_id returns 200 with error", %{conn: conn} do
    conn =
      conn
      |> with_auth()
      |> post(~p"/admin/slack-channels", %{channel_id: "", default_repo: "", notes: ""})
    assert html_response(conn, 200) =~ "Slack Channels"
  end
end

describe "PATCH /admin/slack-channels/:channel_id/toggle" do
  test "toggles enabled flag", %{conn: conn} do
    {:ok, ch} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C333TEST", enabled: true})
    conn =
      conn
      |> with_auth()
      |> patch(~p"/admin/slack-channels/#{ch.channel_id}/toggle")
    assert redirected_to(conn) == ~p"/admin/slack-channels"
    updated = Guild.Repo.get!(Guild.Schema.SlackChannel, "C333TEST")
    assert updated.enabled == false
  end
end

describe "DELETE /admin/slack-channels/:channel_id" do
  test "removes the channel", %{conn: conn} do
    {:ok, ch} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "C444TEST"})
    conn =
      conn
      |> with_auth()
      |> delete(~p"/admin/slack-channels/#{ch.channel_id}")
    assert redirected_to(conn) == ~p"/admin/slack-channels"
    assert Guild.Repo.get(Guild.Schema.SlackChannel, "C444TEST") == nil
  end
end
```

---

## 9. Tests — Events handler gate — `test/guild_web/controllers/slack_controller_test.exs`

Add a new `describe "slack_channels gate"` block. You'll need the existing `slack_events_conn` helper (or define one matching the pattern of `slack_conn` but posting to `/slack/events`). Look at the existing test file — there may already be a helper for posting to `/slack/events`; if not, create one following the same HMAC signing pattern used for commands/interactions.

```elixir
describe "slack_channels gate" do
  setup do
    Application.put_env(:guild, :slack_signing_secret, @test_secret)
    :ok
  end

  defp slack_events_conn(conn, body_map, opts \\ []) do
    body_json = Jason.encode!(body_map)
    ts = to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @test_secret)
    base = "v0:#{ts}:#{body_json}"
    sig = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-slack-request-timestamp", ts)
    |> put_req_header("x-slack-signature", sig)
    |> post(~p"/slack/events", body_json)
  end

  test "top-level message for unconfigured channel records audit Event but no worker enqueued", %{conn: conn} do
    event_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "message",
        "channel" => "CNOTCONFIG",
        "user" => "U123",
        "text" => "hello world",
        "ts" => "1234567890.000001",
        "event_ts" => "1234567890.000001"
      }
    }
    conn = slack_events_conn(conn, event_payload)
    assert conn.status == 200
    # An audit Event row is still recorded (ADR 0016: record all)
    import Ecto.Query
    event = Guild.Repo.one(from e in Guild.Schema.Event,
      where: e.event_type == "slack.message",
      limit: 1)
    assert event != nil
    # No SlackInboxWorker job enqueued (it doesn't exist yet in Slice 1, but assert no unknown jobs either)
    assert Oban.drain_queue(queue: :slack_inbox) == %{cancelled: 0, discard: 0, exhausted: 0, failure: 0, snoozed: 0, success: 0}
  end

  test "top-level message for enabled channel passes gate (returns 200)", %{conn: conn} do
    {:ok, _} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "CENABLED", enabled: true})
    event_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "message",
        "channel" => "CENABLED",
        "user" => "U123",
        "text" => "please fix the bug",
        "ts" => "1234567890.000002",
        "event_ts" => "1234567890.000002"
      }
    }
    conn = slack_events_conn(conn, event_payload)
    assert conn.status == 200
  end

  test "top-level message for disabled channel records audit Event only", %{conn: conn} do
    {:ok, _} = Guild.Repo.insert(%Guild.Schema.SlackChannel{channel_id: "CDISABLED", enabled: false})
    event_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "message",
        "channel" => "CDISABLED",
        "user" => "U123",
        "text" => "another message",
        "ts" => "1234567890.000003",
        "event_ts" => "1234567890.000003"
      }
    }
    conn = slack_events_conn(conn, event_payload)
    assert conn.status == 200
  end
end
```

**Note on Oban in tests:** The gate test asserts `Oban.drain_queue(queue: :slack_inbox)` returns zero counts. If `:slack_inbox` queue isn't configured in test mode, Oban will still return empty counts — that's fine. If Oban isn't available in tests at all, just omit the drain assertion and assert `conn.status == 200` only.

---

## Implementation order

1. Migration → `mix ecto.migrate` (verify it runs clean)
2. Schema module
3. Admin controller actions (4 new actions)
4. Router (4 new routes)
5. Template (`slack_channels.html.heex`)
6. Admin index card
7. Events handler gate (edit `slack_controller.ex`)
8. Tests — admin controller
9. Tests — events gate
10. `mix test --exclude e2e` — all green before opening PR

## PR

Open PR against `main`. Title: `feat(g10/s1): slack_channels table + admin CRUD + events handler gate`. Request review from jhgaylor.

Do not modify `ROADMAP.md` — the orchestrator handles that.
