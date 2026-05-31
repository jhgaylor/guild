# G10 Slice 4 — Operator Review Surface

Repo: jhgaylor/guild. Branch: g10/slice-4-admin-review.
Base off: `main` (6f5bdb3 — Slice 2 merged).
TESTS REQUIRED. Read existing files before editing. No scratch docs outside plan/g10-slice-4/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

**Files you own in this slice (do not touch others):**
- `lib/guild_web/controllers/admin_controller.ex` — new slack_inbox + reclassify actions
- `lib/guild_web/controllers/admin_html/slack_inbox.html.heex` — new template
- `lib/guild_web/router.ex` — new routes
- `lib/guild_web/controllers/admin_html/index.html.heex` — add Slack Inbox card
- `test/guild_web/controllers/admin_controller_test.exs` — extend with new describe blocks

Slice 3 runs in parallel and owns `slack_inbox_worker.ex` and `claiming.ex`. Do not touch those files.

---

## Context

`slack_inbox_events` table and schema exist (Slice 2). This slice adds the operator
review surface: a list page showing classification decisions with reasoning, and
override actions (file as new work, mark as noise).

### Key schemas (already exist — read before editing):

**`Guild.Schema.SlackInboxEvent`** — fields:
`id`, `event_id`, `channel_id`, `user_id`, `user_display_name`, `message_ts`,
`message_text`, `verdict`, `confidence`, `reasoning`, `thread_id`, `action_taken`,
`github_issue_url`, `override_verdict`, `inserted_at`

**`Guild.Schema.SlackChannel`** — fields: `channel_id`, `default_repo`, `enabled`

**Existing admin pattern** — follow `lib/guild_web/controllers/admin_controller.ex`
for action style (no LiveView, plain controller + heex template, form POSTs with
`_method` override for PATCH/DELETE, CSRF token in forms). Read `repos.html.heex`
and `workers.html.heex` for template conventions.

---

## 1. Routes — `lib/guild_web/router.ex`

Inside the existing `scope "/admin"` block (the one inside `pipe_through [:browser, :auth]`),
add after the existing slack-channels routes:

```elixir
get "/slack-inbox", AdminController, :slack_inbox
post "/slack-inbox/:id/reclassify", AdminController, :reclassify_inbox_event
```

---

## 2. Admin controller — `lib/guild_web/controllers/admin_controller.ex`

Read the full file first. Add two new action functions after the existing
`delete_slack_channel/2` action. Also add `import Ecto.Query` if not already present
(check — it may already be there).

### `slack_inbox/2`

```elixir
def slack_inbox(conn, _params) do
  import Ecto.Query

  events =
    Guild.Repo.all(
      from e in Guild.Schema.SlackInboxEvent,
        order_by: [desc: e.inserted_at],
        limit: 50
    )

  render(conn, :slack_inbox, events: events)
end
```

### `reclassify_inbox_event/2`

The "File as new work" override: look up the inbox event, run the `:new_work` action
immediately (regardless of dry-run flag — override is explicit operator decision),
set `override_verdict: "new_work"`.

```elixir
def reclassify_inbox_event(conn, %{"id" => id, "verdict" => verdict}) do
  import Ecto.Query

  event = Guild.Repo.get!(Guild.Schema.SlackInboxEvent, id)
  channel = Guild.Repo.get(Guild.Schema.SlackChannel, event.channel_id)

  case verdict do
    "new_work" ->
      # Run :new_work action immediately (override ignores dry-run flag)
      if channel && channel.default_repo && event.message_text do
        title =
          event.message_text
          |> String.split("\n")
          |> List.first("")
          |> String.slice(0, 80)

        date_str = Date.utc_today() |> Date.to_iso8601()
        body =
          event.message_text <>
          "\n\n> @#{event.user_display_name || event.user_id} in <##{event.channel_id}> on #{date_str} (operator override)"

        case Guild.GitHub.impl().create_issue(channel.default_repo, title, body, ["bot-ready"], [], nil) do
          {:ok, %{"html_url" => issue_url}} ->
            event
            |> Guild.Schema.SlackInboxEvent.changeset(%{
              override_verdict: "new_work",
              action_taken: "issue_created",
              github_issue_url: issue_url
            })
            |> Guild.Repo.update!()

          {:error, _tier, reason} ->
            require Logger
            Logger.warning("AdminController.reclassify_inbox_event: GitHub error: #{inspect(reason)}")
        end
      end

      redirect(conn, to: ~p"/admin/slack-inbox")

    "noise" ->
      event
      |> Guild.Schema.SlackInboxEvent.changeset(%{override_verdict: "noise"})
      |> Guild.Repo.update!()

      redirect(conn, to: ~p"/admin/slack-inbox")

    _ ->
      redirect(conn, to: ~p"/admin/slack-inbox")
  end
end
```

---

## 3. Template — `lib/guild_web/controllers/admin_html/slack_inbox.html.heex`

New file. Follow the style of `repos.html.heex` (container div, page-title, data-table,
`~p` verified routes for form actions, CSRF tokens in forms).

```html
<div class="container">
  <h1 class="page-title">Slack Inbox</h1>
  <p class="page-subtitle"><a href={~p"/admin"}>← Admin</a></p>

  <%= if Enum.empty?(@events) do %>
    <p class="empty-state">No Slack inbox events yet. Enable a channel in <a href={~p"/admin/slack-channels"}>Slack Channels</a> and set <code>SLACK_INBOX_DRY_RUN=false</code> (or leave dry-run on to preview classifications here).</p>
  <% else %>
    <table class="data-table">
      <thead>
        <tr>
          <th>Time</th>
          <th>Channel</th>
          <th>User</th>
          <th>Message</th>
          <th>Verdict</th>
          <th>Confidence</th>
          <th>Action</th>
          <th>Reasoning</th>
          <th>Override</th>
        </tr>
      </thead>
      <tbody>
        <%= for event <- @events do %>
          <tr>
            <td style="white-space:nowrap"><%= Calendar.strftime(event.inserted_at, "%m-%d %H:%M") %></td>
            <td><code><%= event.channel_id %></code></td>
            <td><%= event.user_display_name || event.user_id %></td>
            <td title={event.message_text}>
              <%= String.slice(event.message_text || "", 0, 80) %><%= if String.length(event.message_text || "") > 80, do: "…" %>
            </td>
            <td>
              <span class={"badge #{verdict_badge_class(event.verdict)}"}>
                <%= event.verdict || "—" %>
              </span>
            </td>
            <td>
              <%= if event.confidence, do: "#{round(event.confidence * 100)}%", else: "—" %>
            </td>
            <td>
              <span class={"badge #{action_badge_class(event.action_taken)}"}>
                <%= event.action_taken || "—" %>
              </span>
              <%= if event.github_issue_url do %>
                <br /><a href={event.github_issue_url} target="_blank" rel="noopener">issue ↗</a>
              <% end %>
            </td>
            <td style="max-width:300px;font-size:0.85em">
              <%= event.override_verdict && "[override: #{event.override_verdict}] " %>
              <%= event.reasoning %>
            </td>
            <td>
              <%= if is_nil(event.override_verdict) do %>
                <form method="post" action={~p"/admin/slack-inbox/#{event.id}/reclassify"} style="display:inline">
                  <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                  <input type="hidden" name="verdict" value="new_work" />
                  <button type="submit" class="btn btn--small">File as new work</button>
                </form>
                <form method="post" action={~p"/admin/slack-inbox/#{event.id}/reclassify"} style="display:inline;margin-left:4px">
                  <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                  <input type="hidden" name="verdict" value="noise" />
                  <button type="submit" class="btn btn--small">Mark noise</button>
                </form>
              <% else %>
                <span style="color:#888">overridden</span>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</div>
```

The template uses two helper functions: `verdict_badge_class/1` and `action_badge_class/1`.
Add these to `lib/guild_web/controllers/admin_html.ex` (the view module that `use`s the
template — check how `status_label/1` and `slack_status_label/2` are defined there now;
add alongside them):

```elixir
def verdict_badge_class("new_work"), do: "badge--blue"
def verdict_badge_class("refers_to_existing"), do: "badge--purple"
def verdict_badge_class("noise"), do: "badge--gray"
def verdict_badge_class("failed"), do: "badge--red"
def verdict_badge_class(_), do: "badge--gray"

def action_badge_class("issue_created"), do: "badge--green"
def action_badge_class("reference_reply_posted"), do: "badge--blue"
def action_badge_class("dry_run"), do: "badge--yellow"
def action_badge_class("noise"), do: "badge--gray"
def action_badge_class("failed"), do: "badge--red"
def action_badge_class(_), do: "badge--gray"
```

Find `lib/guild_web/controllers/admin_html.ex` (it may be at that path or embedded in
the controller as `embed_templates` — search for where `status_label` is defined and
add the new helpers there).

---

## 4. Admin index card — `lib/guild_web/controllers/admin_html/index.html.heex`

Add a "Slack Inbox" card to the `admin-cards` div, after the existing "Slack Channels" card:

```html
<a href={~p"/admin/slack-inbox"} class="admin-card">
  <h2>Slack Inbox</h2>
  <p>Review Slack message classifications and override wrong verdicts.</p>
</a>
```

---

## 5. Tests — extend `test/guild_web/controllers/admin_controller_test.exs`

Read the existing file. The `with_auth/1` helper is already defined. Add new describe
blocks after the existing `/admin/slack-channels` tests.

```elixir
describe "GET /admin/slack-inbox" do
  test "without auth returns 401", %{conn: conn} do
    conn = get(conn, ~p"/admin/slack-inbox")
    assert conn.status == 401
  end

  test "with auth returns 200", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/admin/slack-inbox")
    assert html_response(conn, 200) =~ "Slack Inbox"
  end

  test "lists existing inbox events", %{conn: conn} do
    {:ok, _} = Guild.Repo.insert(
      Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
        event_id: "evt_admin_test",
        channel_id: "C_ADMIN",
        user_id: "U_ADMIN",
        message_ts: "111.222",
        message_text: "fix the login bug please",
        verdict: "new_work",
        confidence: 0.92,
        reasoning: "direct task request",
        action_taken: "dry_run"
      })
    )
    conn = conn |> with_auth() |> get(~p"/admin/slack-inbox")
    body = html_response(conn, 200)
    assert body =~ "C_ADMIN"
    assert body =~ "fix the login bug"
  end
end

describe "POST /admin/slack-inbox/:id/reclassify — mark noise" do
  test "sets override_verdict to noise and redirects", %{conn: conn} do
    {:ok, event} = Guild.Repo.insert(
      Guild.Schema.SlackInboxEvent.changeset(%Guild.Schema.SlackInboxEvent{}, %{
        event_id: "evt_reclassify_noise",
        channel_id: "C_RECLASSIFY",
        user_id: "U123",
        message_ts: "111.333",
        message_text: "good morning everyone",
        verdict: "new_work",
        confidence: 0.75,
        reasoning: "seemed like a task",
        action_taken: "dry_run"
      })
    )

    conn =
      conn
      |> with_auth()
      |> post(~p"/admin/slack-inbox/#{event.id}/reclassify", %{"verdict" => "noise"})

    assert redirected_to(conn) == ~p"/admin/slack-inbox"

    updated = Guild.Repo.get!(Guild.Schema.SlackInboxEvent, event.id)
    assert updated.override_verdict == "noise"
  end
end
```

For the "File as new work" override test: it requires a GitHub API call. If the test
environment uses `Guild.GitHub.TestAdapter`, configure it to return a fake issue response.
Check `lib/guild/github/test_adapter.ex` and `config/test.exs` to understand how to
set up responses before writing this test. Keep it simple — if stubbing is complex, the
`:noise` override test above is sufficient for the acceptance criteria. Add the `:new_work`
override test only if you can stub GitHub cleanly in < 10 lines of setup.

---

## Implementation order

1. Read `lib/guild_web/router.ex` — understand existing admin scope structure
2. Read `lib/guild_web/controllers/admin_controller.ex` in full
3. Read `lib/guild_web/controllers/admin_html/repos.html.heex` — template conventions
4. Find where `status_label/1` is defined (admin_html.ex or embedded in controller)
5. Add routes to `router.ex`
6. Add `slack_inbox/2` and `reclassify_inbox_event/2` to `admin_controller.ex`
7. Create `slack_inbox.html.heex`
8. Add badge helpers to the admin_html view module
9. Add "Slack Inbox" card to `index.html.heex`
10. Extend `admin_controller_test.exs` with new describe blocks
11. `mix test --exclude e2e` — all green
12. Open PR against `main`. Title: `feat(g10/s4): /admin/slack-inbox review surface`. Request review from jhgaylor.

Do not modify `ROADMAP.md`.
