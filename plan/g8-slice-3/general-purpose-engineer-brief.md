# G8 Slice 3 — Workers List/Add + Inline Thread Actions

Repo: jhgaylor/guild. Branch: g8/slice-3-workers-thread-actions.
TESTS REQUIRED. Read existing schemas/controllers/router before editing.
Do NOT create scratch docs outside plan/g8-slice-3/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

---

## Context from codebase reading

### Guild.Schema.Worker fields (lib/guild/schema/worker.ex)
- Primary key: `worker_id` (string, autogenerate: false)
- Fields: `fountain_agent_id` (string), `vault_id` (string), `github_installation_id` (string, nullable)
- `changeset/2` casts all four fields; validates_required: `[:worker_id, :fountain_agent_id, :vault_id]`
- `github_installation_id` is optional (not in validate_required)

### Guild.Control function signatures (lib/guild/control.ex)
- `Guild.Control.hold(ref)` — ref is a UUID string or GitHub issue number string; sets held=true, cancels Oban ClaimWorker jobs
- `Guild.Control.resume(ref)` — sets held=false
- `Guild.Control.abandon(ref)` — transitions to :abandoned terminal state + cancels Oban jobs
- All return `{:ok, message}` or `{:error, reason}`

### Thread schema (lib/guild/schema/thread.ex)
- `state` is stored as a **string** (field :state, :string), not atom
- `held` is a boolean field (field :held, :boolean, default: false)
- Valid states: `~w(unnoticed noticed claimed executing pr_open planned blocked done abandoned)`
- Terminal states: `"done"`, `"abandoned"`

### Router structure (lib/guild_web/router.ex)
- Main auth scope: `scope "/", GuildWeb do pipe_through [:browser, :auth]`
- Inside that scope, `/threads` live route: `live "/threads/:id", ThreadLive, :show` inside `live_session :authenticated`
- Admin sub-scope: `scope "/admin" do` nested inside the auth scope — `get "/workers"` already exists
- Thread action POST routes must go inside the `scope "/", GuildWeb do pipe_through [:browser, :auth]` block

### AdminController workers/2 (lib/guild_web/controllers/admin_controller.ex)
- Current placeholder: `def workers(conn, _params) do render(conn, :workers) end`
- The `repos/2` action shows the pattern: query all rows, build changeset, render with assigns

### thread_live.html.heex layout
- Stuck warning banner at top (conditional)
- `<h1>` with anchor_label + state badge
- `<section class="info-card">` with `<dl class="info-grid">` — **insert action buttons AFTER this section, BEFORE the `<h2>` Timeline header**
- Thread assigns available: `@thread.state` (string), `@thread.held` (boolean), `@thread.id` (UUID string)

---

## 1. /admin/workers list + add

### Routes — add to the nested `/admin` scope in lib/guild_web/router.ex:

```elixir
scope "/admin" do
  get "/", AdminController, :index
  get "/repos", AdminController, :repos
  post "/repos", AdminController, :create_repo
  patch "/repos/:encoded_name/toggle", AdminController, :toggle_repo
  delete "/repos/:encoded_name", AdminController, :disable_repo
  get "/workers", AdminController, :workers
  post "/workers", AdminController, :create_worker   # ADD THIS LINE
  get "/integrations", AdminController, :integrations
end
```

### Controller actions in lib/guild_web/controllers/admin_controller.ex

Replace the `workers/2` placeholder body:

```elixir
def workers(conn, _params) do
  workers = Guild.Repo.all(Guild.Schema.Worker)
  changeset = Guild.Schema.Worker.changeset(%Guild.Schema.Worker{}, %{})
  render(conn, :workers, workers: workers, changeset: changeset)
end
```

Add new `create_worker/2` action:

```elixir
def create_worker(conn, params) do
  attrs = %{
    worker_id: String.trim(params["worker_id"] || ""),
    fountain_agent_id: String.trim(params["fountain_agent_id"] || ""),
    vault_id: String.trim(params["vault_id"] || ""),
    github_installation_id: case String.trim(params["github_installation_id"] || "") do
      "" -> nil
      v -> v
    end
  }

  changeset =
    Guild.Schema.Worker.changeset(%Guild.Schema.Worker{}, attrs)
    |> Map.put(:action, :insert)

  case Guild.Repo.insert(changeset) do
    {:ok, _worker} ->
      redirect(conn, to: ~p"/admin/workers")

    {:error, changeset} ->
      workers = Guild.Repo.all(Guild.Schema.Worker)
      conn
      |> put_status(200)
      |> render(:workers, workers: workers, changeset: changeset)
  end
end
```

### Template lib/guild_web/controllers/admin_html/workers.html.heex

Replace the placeholder entirely:

```heex
<div class="container">
  <h1 class="page-title">Workers</h1>
  <p class="page-subtitle"><a href={~p"/admin"}>← Admin</a></p>

  <%= if Enum.empty?(@workers) do %>
    <p class="empty-state">No workers configured yet.</p>
  <% else %>
    <table class="table">
      <thead>
        <tr>
          <th>Worker ID</th>
          <th>Fountain Agent ID</th>
          <th>Vault ID</th>
          <th>GitHub Installation ID</th>
        </tr>
      </thead>
      <tbody>
        <%= for worker <- @workers do %>
          <tr>
            <td><code><%= worker.worker_id %></code></td>
            <td><code><%= worker.fountain_agent_id %></code></td>
            <td><code><%= worker.vault_id %></code></td>
            <td><code><%= worker.github_installation_id || "—" %></code></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>

  <h2 class="section-title" style="margin-top: 2rem;">Add Worker</h2>
  <p style="margin-bottom: 1rem; color: #666;">
    These are reference IDs only — no secret values (API keys, tokens) are stored or displayed here.
  </p>

  <.form :let={f} for={@changeset} action={~p"/admin/workers"} method="post">
    <div class="form-group">
      <label for="worker_id">Worker ID <span style="color: red;">*</span></label>
      <%= text_input f, :worker_id, placeholder: "e.g. default", class: "form-control", required: true %>
      <%= error_tag f, :worker_id %>
    </div>

    <div class="form-group">
      <label for="fountain_agent_id">Fountain Agent ID <span style="color: red;">*</span></label>
      <%= text_input f, :fountain_agent_id, placeholder: "UUID of the Fountain agent", class: "form-control", required: true %>
      <%= error_tag f, :fountain_agent_id %>
    </div>

    <div class="form-group">
      <label for="vault_id">Vault ID <span style="color: red;">*</span></label>
      <%= text_input f, :vault_id, placeholder: "UUID of the Fountain vault", class: "form-control", required: true %>
      <%= error_tag f, :vault_id %>
    </div>

    <div class="form-group">
      <label for="github_installation_id">GitHub Installation ID (optional)</label>
      <%= text_input f, :github_installation_id, placeholder: "GitHub App installation ID", class: "form-control" %>
      <%= error_tag f, :github_installation_id %>
    </div>

    <%= submit "Add Worker", class: "btn btn--primary" %>
  </.form>
</div>
```

---

## 2. Inline thread actions — POST controller endpoints

### New controller: lib/guild_web/controllers/thread_action_controller.ex

```elixir
defmodule GuildWeb.ThreadActionController do
  use GuildWeb, :controller

  def hold(conn, %{"id" => id}) do
    Guild.Control.hold(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end

  def resume(conn, %{"id" => id}) do
    Guild.Control.resume(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end

  def abandon(conn, %{"id" => id}) do
    Guild.Control.abandon(id)
    redirect(conn, to: ~p"/threads/#{id}")
  end
end
```

### Routes — add inside the `scope "/", GuildWeb do pipe_through [:browser, :auth]` block in lib/guild_web/router.ex, alongside the existing `/threads` routes:

```elixir
post "/threads/:id/hold", ThreadActionController, :hold
post "/threads/:id/resume", ThreadActionController, :resume
post "/threads/:id/abandon", ThreadActionController, :abandon
```

Place these BEFORE the `live_session` block to avoid conflicts.

### Thread LiveView buttons in lib/guild_web/live/thread_live.html.heex

Insert this section AFTER the closing `</section>` of the `info-card` and BEFORE the `<h2 class="section-title">Timeline` heading:

```heex
  <%# Thread action buttons — plain HTML POST forms, not LiveView events %>
  <% terminal_states = ["done", "abandoned"] %>
  <% is_terminal = @thread.state in terminal_states %>

  <%= unless is_terminal do %>
    <div class="thread-actions" style="margin: 1rem 0; display: flex; gap: 0.5rem; flex-wrap: wrap;">
      <%= unless @thread.held do %>
        <% active_states = ["executing", "pr_open"] %>
        <%= if @thread.state in active_states do %>
          <form action={~p"/threads/#{@thread.id}/hold"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn--warning">Hold</button>
          </form>
        <% end %>
      <% end %>

      <%= if @thread.held do %>
        <form action={~p"/threads/#{@thread.id}/resume"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button type="submit" class="btn btn--primary">Resume</button>
        </form>
      <% end %>

      <form action={~p"/threads/#{@thread.id}/abandon"} method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <button type="submit" class="btn btn--danger"
          onclick="return confirm('Abandon this thread? This cannot be undone.')">
          Abandon
        </button>
      </form>
    </div>
  <% end %>
```

**Important:** `@thread.state` is a string (not atom). Use string comparisons: `"executing"`, `"pr_open"`, `"done"`, `"abandoned"`.

---

## 3. Tests

### Extend test/guild_web/controllers/admin_controller_test.exs

Add a new describe block:

```elixir
describe "GET /admin/workers" do
  test "with auth returns 200 and renders workers table", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/admin/workers")
    body = html_response(conn, 200)
    assert body =~ "Workers"
  end

  test "with auth renders seeded worker in table", %{conn: conn} do
    Guild.Repo.insert!(%Guild.Schema.Worker{
      worker_id: "test-worker",
      fountain_agent_id: "agent-uuid",
      vault_id: "vault-uuid"
    })
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Worker) end)

    conn = conn |> with_auth() |> get(~p"/admin/workers")
    assert html_response(conn, 200) =~ "test-worker"
  end
end

describe "POST /admin/workers" do
  setup do
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Worker) end)
    :ok
  end

  test "with valid params creates worker and redirects", %{conn: conn} do
    conn = conn |> with_auth() |> post(~p"/admin/workers", %{
      worker_id: "new-worker",
      fountain_agent_id: "agent-abc",
      vault_id: "vault-abc"
    })
    assert redirected_to(conn) == ~p"/admin/workers"
    assert Guild.Repo.get(Guild.Schema.Worker, "new-worker") != nil
  end

  test "with missing worker_id returns 200 with error", %{conn: conn} do
    conn = conn |> with_auth() |> post(~p"/admin/workers", %{
      worker_id: "",
      fountain_agent_id: "agent-abc",
      vault_id: "vault-abc"
    })
    body = html_response(conn, 200)
    assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
    assert Guild.Repo.aggregate(Guild.Schema.Worker, :count, :worker_id) == 0
  end

  test "with missing fountain_agent_id returns 200 with error", %{conn: conn} do
    conn = conn |> with_auth() |> post(~p"/admin/workers", %{
      worker_id: "new-worker",
      fountain_agent_id: "",
      vault_id: "vault-abc"
    })
    body = html_response(conn, 200)
    assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
  end
end
```

### New test/guild_web/controllers/thread_action_controller_test.exs

```elixir
defmodule GuildWeb.ThreadActionControllerTest do
  use GuildWeb.ConnCase

  @username System.get_env("OPERATOR_USERNAME", "test_operator")
  @password System.get_env("OPERATOR_PASSWORD", "test_password")

  defp with_auth(conn) do
    credentials = Base.encode64("#{@username}:#{@password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp insert_worker! do
    Guild.Repo.insert!(%Guild.Schema.Worker{
      worker_id: "test-worker",
      fountain_agent_id: "agent-uuid",
      vault_id: "vault-uuid"
    })
  end

  defp insert_thread!(attrs \\ %{}) do
    defaults = %Guild.Schema.Thread{
      anchor_type: "github_issue",
      anchor_id: "999",
      state: "executing",
      held: false
    }
    Guild.Repo.insert!(Map.merge(defaults, attrs))
  end

  setup do
    insert_worker!()
    on_exit(fn ->
      Guild.Repo.delete_all(Guild.Schema.Thread)
      Guild.Repo.delete_all(Guild.Schema.Worker)
    end)
    :ok
  end

  describe "POST /threads/:id/hold" do
    test "without auth returns 401", %{conn: conn} do
      thread = insert_thread!()
      conn = post(conn, ~p"/threads/#{thread.id}/hold")
      assert conn.status == 401
    end

    test "with auth on executing thread sets held=true and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: false})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/hold")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.held == true
    end
  end

  describe "POST /threads/:id/resume" do
    test "with auth on held thread sets held=false and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: true})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/resume")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.held == false
    end
  end

  describe "POST /threads/:id/abandon" do
    test "with auth on non-terminal thread transitions to abandoned and redirects", %{conn: conn} do
      thread = insert_thread!(%{state: "executing", held: false})
      conn = conn |> with_auth() |> post(~p"/threads/#{thread.id}/abandon")
      assert redirected_to(conn) == ~p"/threads/#{thread.id}"
      updated = Guild.Repo.get!(Guild.Schema.Thread, thread.id)
      assert updated.state == "abandoned"
    end
  end
end
```

### LiveView button visibility tests

Add to test/guild_web/live/thread_live_test.exs (or create it if absent):

```elixir
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
```

---

## Implementation checklist

1. Add `post "/workers", AdminController, :create_worker` to the `/admin` scope in router.ex
2. Add `post "/threads/:id/hold"`, `post "/threads/:id/resume"`, `post "/threads/:id/abandon"` to the top-level `:auth` scope in router.ex (inside `scope "/", GuildWeb do pipe_through [:browser, :auth]`, before or after the `live_session` block)
3. Replace `workers/2` body + add `create_worker/2` in admin_controller.ex
4. Replace workers.html.heex placeholder with table + form
5. Create lib/guild_web/controllers/thread_action_controller.ex
6. Insert action buttons into thread_live.html.heex after `</section>` (info-card), before `<h2>Timeline`
7. Extend admin_controller_test.exs with workers GET/POST tests
8. Create thread_action_controller_test.exs
9. Add/extend thread_live_test.exs with button visibility tests
10. Run `mix test --exclude e2e` — must be green
11. Commit + push + open PR to main

## Critical reminders

- `@thread.state` is a **string**, not an atom. Use `"executing"`, `"done"`, etc. in comparisons.
- Thread action routes are **plain controller POST endpoints**, NOT LiveView push events.
- Include `<input type="hidden" name="_csrf_token" value={get_csrf_token()} />` in all form POSTs.
- DO NOT display actual secret values (API keys, tokens) through the workers UI — reference IDs (fountain_agent_id, vault_id, github_installation_id) only.
- No mix.exs/Dockerfile build hacks. No compile:true/override:true entries.
- Do NOT create scratch docs outside plan/g8-slice-3/
- `mix test --exclude e2e` must be green before opening the PR.
