# G8 Slice 2 — Repos CRUD + Setup-Readiness Banner

Repo: jhgaylor/guild. Branch: g8/slice-2-repos-banner.
TESTS REQUIRED. Read existing schemas/controllers before editing.
Do NOT create scratch docs outside plan/g8-slice-2/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

## Concrete schema facts (verified by reading source)

- `Guild.Schema.Repo` — primary key: `full_name` (string, not auto-generated). Fields: `full_name`, `enabled` (boolean, default true), `worker_id` (string). Timestamps: `inserted_at`, `updated_at` (utc_datetime_usec).
- `Guild.Schema.Worker` — primary key: `worker_id` (string, not auto-generated). Fields: `worker_id`, `fountain_agent_id`, `vault_id`, `github_installation_id`. Timestamps.
- `Guild.Schema.Thread` — primary key: `id` (binary_id). Fields: `anchor_type`, `anchor_id`, `anchor_url`, `state`, `owner`, `parent_thread_id`, `linear_issue_id`, `last_alerted_at`, `held`, `state_entered_at`. Timestamps.
  - **IMPORTANT**: Thread has NO foreign key to repos. Threads reference repos only indirectly: `anchor_type = "github_issue"` and `anchor_id = issue_number` (string). There is NO `repo_full_name` field on Thread.
  - For `last_claim_at`: since there is no FK, use `inserted_at` of the most recent Thread where `anchor_type == "github_issue"` filtered by `anchor_url` LIKE `"%#{repo.full_name}%"` — but `anchor_url` is often nil. Simplest approach: show "N/A" for last_claim_at (just pass `nil` and display "never"). This is acceptable at this scale.
- `Guild.Release.add_repo/3` signature: `add_repo(full_name, worker_id \\ "default", enabled \\ true)` — uses `Ecto.Migrator.with_repo/2`, so it calls `load_app()` and wraps in a repo context. **Do NOT call this from the web controller** — it is a release task. Instead, in `create_repo/2`, use `Guild.Repo.insert/2` directly with `Guild.Schema.Repo.changeset/2` and `on_conflict: :nothing, conflict_target: :full_name`.
- `GuildWeb.Format.time_ago/1` — accepts `DateTime`, `NaiveDateTime`, or `nil` (returns "unknown").

## 1. /admin/repos CRUD

### Routes — add to the existing scope "/admin" block in lib/guild_web/router.ex:

The existing block is:
```elixir
scope "/admin" do
  get "/", AdminController, :index
  get "/repos", AdminController, :repos      # already exists (placeholder) — no-op
  get "/workers", AdminController, :workers
  get "/integrations", AdminController, :integrations
end
```

Add these three routes inside the same `scope "/admin"` block:
```elixir
  post "/repos", AdminController, :create_repo
  patch "/repos/:encoded_name/toggle", AdminController, :toggle_repo
  delete "/repos/:encoded_name", AdminController, :disable_repo
```

Note: full_name contains "/" — URL-encode it with `URI.encode_www_form/1` in templates;
decode with `URI.decode_www_form/1` in controller params. The `:encoded_name` path param
receives the encoded form.

### Controller actions in lib/guild_web/controllers/admin_controller.ex:

**repos/2** (already exists as placeholder — replace body):
```elixir
def repos(conn, _params) do
  repos = Guild.Repo.all(Guild.Schema.Repo)
  workers = Guild.Repo.all(Guild.Schema.Worker)
  changeset = Ecto.Changeset.change(%Guild.Schema.Repo{})
  render(conn, :repos, repos: repos, workers: workers, changeset: changeset)
end
```
Note: last_claim_at is not available without a FK — pass `nil` for each repo and show "never" in the template. Do NOT attempt a per-repo Thread query since Thread has no repo FK.

**create_repo/2**:
```elixir
def create_repo(conn, params) do
  full_name = String.trim(params["full_name"] || "")
  worker_id = case String.trim(params["worker_id"] || "") do
    "" -> "default"
    wid -> wid
  end

  if full_name == "" do
    repos = Guild.Repo.all(Guild.Schema.Repo)
    workers = Guild.Repo.all(Guild.Schema.Worker)
    changeset =
      Guild.Schema.Repo.changeset(%Guild.Schema.Repo{}, %{full_name: "", worker_id: worker_id})
      |> Ecto.Changeset.add_error(:full_name, "can't be blank")
      |> Map.put(:action, :insert)
    conn
    |> put_status(200)
    |> render(:repos, repos: repos, workers: workers, changeset: changeset)
  else
    changeset = Guild.Schema.Repo.changeset(%Guild.Schema.Repo{}, %{
      full_name: full_name,
      worker_id: worker_id,
      enabled: true
    })
    Guild.Repo.insert(changeset, on_conflict: :nothing, conflict_target: :full_name)
    redirect(conn, to: ~p"/admin/repos")
  end
end
```

**toggle_repo/2**:
```elixir
def toggle_repo(conn, %{"encoded_name" => encoded}) do
  full_name = URI.decode_www_form(encoded)
  repo = Guild.Repo.get!(Guild.Schema.Repo, full_name)
  changeset = Ecto.Changeset.change(repo, enabled: !repo.enabled)
  Guild.Repo.update!(changeset)
  redirect(conn, to: ~p"/admin/repos")
end
```

**disable_repo/2**:
```elixir
def disable_repo(conn, %{"encoded_name" => encoded}) do
  full_name = URI.decode_www_form(encoded)
  repo = Guild.Repo.get!(Guild.Schema.Repo, full_name)
  changeset = Ecto.Changeset.change(repo, enabled: false)
  Guild.Repo.update!(changeset)
  redirect(conn, to: ~p"/admin/repos")
end
```

### Template lib/guild_web/controllers/admin_html/repos.html.heex (replace placeholder):

- Table: columns `full_name`, `enabled` (badge: green "enabled" / red "disabled"), `worker_id`,
  `last_claim_at` (show "never" since Thread has no repo FK — always pass nil).
- Per-row toggle button: form with `method="post"` + `_method="patch"` to `/admin/repos/<encoded>/toggle`.
- Per-row disable button (if enabled): form with `method="post"` + `_method="delete"` to
  `/admin/repos/<encoded>` — use `data-confirm` attribute for a JS confirm dialog; if no JS, a single POST is acceptable since soft-disable is reversible.
- Add-repo form below the table: `full_name` text input, `worker_id` `<select>` built from `@workers`
  assigns (each option: `worker.worker_id` as value and label), submit button "Add repo".
- Show validation errors from `@changeset` if present.

Example template structure:
```heex
<div class="container">
  <h1 class="page-title">Repos</h1>
  <p class="page-subtitle"><a href={~p"/admin"}>← Admin</a></p>

  <table>
    <thead>
      <tr>
        <th>Repo</th><th>Status</th><th>Worker</th><th>Last Claim</th><th>Actions</th>
      </tr>
    </thead>
    <tbody>
      <%= for repo <- @repos do %>
        <tr>
          <td><%= repo.full_name %></td>
          <td>
            <%= if repo.enabled do %>
              <span class="badge badge--green">enabled</span>
            <% else %>
              <span class="badge badge--red">disabled</span>
            <% end %>
          </td>
          <td><%= repo.worker_id %></td>
          <td>never</td>
          <td>
            <form method="post" action={~p"/admin/repos/#{URI.encode_www_form(repo.full_name)}/toggle"}>
              <input type="hidden" name="_method" value="patch" />
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button type="submit"><%= if repo.enabled, do: "Disable", else: "Enable" %></button>
            </form>
            <%= if repo.enabled do %>
              <form method="post" action={~p"/admin/repos/#{URI.encode_www_form(repo.full_name)}"}>
                <input type="hidden" name="_method" value="delete" />
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <button type="submit" data-confirm="Disable this repo?">Disable</button>
              </form>
            <% end %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>

  <h2>Add Repo</h2>
  <.form for={@changeset} action={~p"/admin/repos"} method="post">
    <.input field={@changeset[:full_name]} label="Full name (owner/repo)" />
    <select name="worker_id">
      <%= for worker <- @workers do %>
        <option value={worker.worker_id}><%= worker.worker_id %></option>
      <% end %>
    </select>
    <button type="submit">Add repo</button>
  </.form>
</div>
```

NOTE: Use Phoenix's built-in `<.form>` and `<.input>` components (from `core_components.ex`) for the add form — they handle CSRF automatically. For the toggle/delete forms, include `_csrf_token` manually since they're raw HTML forms. Check how existing admin templates handle forms (look at workers.html.heex if it exists, or integrations.html.heex for reference style).

## 2. Setup-readiness banner

### Guild.Setup module — lib/guild/setup.ex (NEW):
```elixir
defmodule Guild.Setup do
  import Ecto.Query

  def gaps() do
    enabled_repos =
      Guild.Repo.aggregate(
        from(r in Guild.Schema.Repo, where: r.enabled == true),
        :count,
        :full_name
      )

    workers_count = Guild.Repo.aggregate(Guild.Schema.Worker, :count, :worker_id)

    []
    |> then(fn gaps -> if enabled_repos == 0, do: [:no_repos | gaps], else: gaps end)
    |> then(fn gaps -> if workers_count == 0, do: [:no_workers | gaps], else: gaps end)
  end
end
```

Note: `Guild.Repo.aggregate/3` (the Ecto repo, not `Guild.Schema.Repo`) does not accept a where-clause directly. Use the query form above. Import `Ecto.Query` at the top of the module.

### Banner partial — lib/guild_web/components/readiness_banner.html.heex (NEW):
```heex
<%= if @gaps != [] do %>
  <div class="readiness-banner">
    <%= if :no_repos in @gaps do %>
      <div class="readiness-banner__item readiness-banner__item--warning">
        No repos configured. Add one in <a href={~p"/admin/repos"}>Admin → Repos</a> to start claiming issues.
      </div>
    <% end %>
    <%= if :no_workers in @gaps do %>
      <div class="readiness-banner__item readiness-banner__item--warning">
        No workers configured. Add a worker in <a href={~p"/admin/workers"}>Admin → Workers</a>.
      </div>
    <% end %>
  </div>
<% end %>
```

### Rendering the banner partial

Phoenix does not support rendering `.html.heex` partials via `render/2` the same way Rails does. The recommended approach is to use a **function component** instead. Create the banner as a function component in a module, for example in `lib/guild_web/components/readiness_banner.ex`:

```elixir
defmodule GuildWeb.ReadinessBanner do
  use Phoenix.Component
  use GuildWeb, :verified_routes

  attr :gaps, :list, default: []

  def banner(assigns) do
    ~H"""
    <%= if @gaps != [] do %>
      <div class="readiness-banner">
        <%= if :no_repos in @gaps do %>
          <div class="readiness-banner__item readiness-banner__item--warning">
            No repos configured. Add one in <a href={~p"/admin/repos"}>Admin → Repos</a> to start claiming issues.
          </div>
        <% end %>
        <%= if :no_workers in @gaps do %>
          <div class="readiness-banner__item readiness-banner__item--warning">
            No workers configured. Add a worker in <a href={~p"/admin/workers"}>Admin → Workers</a>.
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
```

Then in templates, import or alias and call `<GuildWeb.ReadinessBanner.banner gaps={@gaps} />` (or `<.banner gaps={@gaps} />` if imported).

Alternatively, you can inline the banner logic directly in the home and threads index templates rather than creating a shared partial — that is simpler and also acceptable.

### Wire the banner:

**lib/guild_web/controllers/page_controller.ex** — replace `home/2`:
```elixir
def home(conn, _params) do
  gaps = Guild.Setup.gaps()
  render(conn, :home, gaps: gaps)
end
```

**lib/guild_web/controllers/page_html/home.html.heex** — add banner at top:
```heex
<GuildWeb.ReadinessBanner.banner gaps={@gaps} />
<div class="landing">
  ... (existing content unchanged)
</div>
```

**lib/guild_web/controllers/thread_controller.ex** — update `index/2`:
```elixir
def index(conn, _params) do
  threads = Guild.Repo.all(from t in Guild.Schema.Thread, order_by: [desc: t.updated_at])
  recent =
    Guild.Repo.all(
      from t in Guild.Schema.Thread,
        order_by: [desc: fragment("COALESCE(?, ?)", t.state_entered_at, t.updated_at)],
        limit: 5
    )
  gaps = Guild.Setup.gaps()
  render(conn, :index, threads: threads, recent: recent, gaps: gaps)
end
```

**lib/guild_web/controllers/thread_html/index.html.heex** — add banner at top (before existing content):
```heex
<GuildWeb.ReadinessBanner.banner gaps={@gaps} />
... (existing content)
```

## 3. Tests — extend test/guild_web/controllers/admin_controller_test.exs

Add these test blocks. Use the existing `with_auth/1` helper and `@username`/`@password` module attributes already defined.

```elixir
describe "GET /admin/repos" do
  test "with auth returns 200", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/admin/repos")
    assert html_response(conn, 200) =~ "Repos"
  end

  test "with auth renders seeded repo in table", %{conn: conn} do
    Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/testrepo", worker_id: "default", enabled: true})
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)

    conn = conn |> with_auth() |> get(~p"/admin/repos")
    assert html_response(conn, 200) =~ "owner/testrepo"
  end
end

describe "POST /admin/repos" do
  setup do
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
    :ok
  end

  test "with valid full_name creates repo and redirects", %{conn: conn} do
    conn = conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
    assert redirected_to(conn) == ~p"/admin/repos"
    assert Guild.Repo.get(Guild.Schema.Repo, "owner/testrepo") != nil
  end

  test "second POST with same full_name is a no-op (idempotent)", %{conn: conn} do
    conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
    conn2 = build_conn() |> with_auth() |> post(~p"/admin/repos", %{full_name: "owner/testrepo", worker_id: "default"})
    assert redirected_to(conn2) == ~p"/admin/repos"
    assert Guild.Repo.aggregate(Guild.Schema.Repo, :count, :full_name) == 1
  end

  test "with blank full_name returns 200 with error and no row created", %{conn: conn} do
    conn = conn |> with_auth() |> post(~p"/admin/repos", %{full_name: "", worker_id: "default"})
    body = html_response(conn, 200)
    assert body =~ "can&#39;t be blank" or body =~ "can't be blank"
    assert Guild.Repo.aggregate(Guild.Schema.Repo, :count, :full_name) == 0
  end
end

describe "PATCH /admin/repos/:encoded_name/toggle" do
  setup do
    Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/togglerepo", worker_id: "default", enabled: true})
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
    :ok
  end

  test "flips enabled from true to false", %{conn: conn} do
    encoded = URI.encode_www_form("owner/togglerepo")
    conn = conn |> with_auth() |> patch(~p"/admin/repos/#{encoded}/toggle")
    assert redirected_to(conn) == ~p"/admin/repos"
    repo = Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo")
    assert repo.enabled == false
  end

  test "flips enabled from false to true", %{conn: conn} do
    Guild.Repo.update!(Ecto.Changeset.change(Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo"), enabled: false))
    encoded = URI.encode_www_form("owner/togglerepo")
    conn = conn |> with_auth() |> patch(~p"/admin/repos/#{encoded}/toggle")
    assert redirected_to(conn) == ~p"/admin/repos"
    repo = Guild.Repo.get!(Guild.Schema.Repo, "owner/togglerepo")
    assert repo.enabled == true
  end
end

describe "DELETE /admin/repos/:encoded_name" do
  setup do
    Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/deleterepo", worker_id: "default", enabled: true})
    on_exit(fn -> Guild.Repo.delete_all(Guild.Schema.Repo) end)
    :ok
  end

  test "sets enabled: false without hard-deleting the row", %{conn: conn} do
    encoded = URI.encode_www_form("owner/deleterepo")
    conn = conn |> with_auth() |> delete(~p"/admin/repos/#{encoded}")
    assert redirected_to(conn) == ~p"/admin/repos"
    repo = Guild.Repo.get(Guild.Schema.Repo, "owner/deleterepo")
    assert repo != nil
    assert repo.enabled == false
  end
end
```

### Banner tests — create test/guild/setup_test.exs:

```elixir
defmodule Guild.SetupTest do
  use Guild.DataCase

  describe "gaps/0" do
    setup do
      on_exit(fn ->
        Guild.Repo.delete_all(Guild.Schema.Repo)
        Guild.Repo.delete_all(Guild.Schema.Worker)
      end)
      :ok
    end

    test "returns [:no_repos, :no_workers] when both are empty" do
      gaps = Guild.Setup.gaps()
      assert :no_repos in gaps
      assert :no_workers in gaps
    end

    test "returns [] when at least one enabled repo and one worker exist" do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-id",
        vault_id: "vault-id"
      })
      Guild.Repo.insert!(%Guild.Schema.Repo{
        full_name: "owner/repo",
        worker_id: "test-worker",
        enabled: true
      })
      assert Guild.Setup.gaps() == []
    end

    test "returns :no_repos when all repos are disabled" do
      Guild.Repo.insert!(%Guild.Schema.Worker{
        worker_id: "test-worker",
        fountain_agent_id: "agent-id",
        vault_id: "vault-id"
      })
      Guild.Repo.insert!(%Guild.Schema.Repo{
        full_name: "owner/repo",
        worker_id: "test-worker",
        enabled: false
      })
      gaps = Guild.Setup.gaps()
      assert :no_repos in gaps
    end
  end
end
```

### Banner integration tests — add to test/guild_web/controllers/admin_controller_test.exs:

```elixir
describe "GET / banner" do
  setup do
    on_exit(fn ->
      Guild.Repo.delete_all(Guild.Schema.Repo)
      Guild.Repo.delete_all(Guild.Schema.Worker)
    end)
    :ok
  end

  test "with zero repos shows no repos configured message", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "No repos configured"
  end

  test "with one enabled repo, banner is absent for repos gap", %{conn: conn} do
    Guild.Repo.insert!(%Guild.Schema.Worker{
      worker_id: "bw",
      fountain_agent_id: "agent",
      vault_id: "vault"
    })
    Guild.Repo.insert!(%Guild.Schema.Repo{full_name: "owner/r", worker_id: "bw", enabled: true})
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    refute body =~ "No repos configured"
  end
end

describe "GET /threads banner" do
  setup do
    on_exit(fn ->
      Guild.Repo.delete_all(Guild.Schema.Repo)
      Guild.Repo.delete_all(Guild.Schema.Worker)
    end)
    :ok
  end

  test "with zero repos shows no repos configured message", %{conn: conn} do
    conn = conn |> with_auth() |> get(~p"/threads")
    body = html_response(conn, 200)
    assert body =~ "No repos configured"
  end
end
```

## Implementation checklist

1. Add routes to `lib/guild_web/router.ex` (post/patch/delete inside the `/admin` scope, inside the `[:browser, :auth]` pipe)
2. Replace `repos/2` body and add `create_repo/2`, `toggle_repo/2`, `disable_repo/2` to `lib/guild_web/controllers/admin_controller.ex`
3. Replace `lib/guild_web/controllers/admin_html/repos.html.heex` with a working table + add form
4. Create `lib/guild/setup.ex` with `Guild.Setup.gaps/0`
5. Create `lib/guild_web/components/readiness_banner.ex` with `GuildWeb.ReadinessBanner.banner/1` function component
6. Update `lib/guild_web/controllers/page_controller.ex` to pass `gaps:` assign
7. Update `lib/guild_web/controllers/page_html/home.html.heex` to render the banner
8. Update `lib/guild_web/controllers/thread_controller.ex` to pass `gaps:` assign
9. Update `lib/guild_web/controllers/thread_html/index.html.heex` to render the banner
10. Write tests in `test/guild_web/controllers/admin_controller_test.exs` and `test/guild/setup_test.exs`
11. Run `mix test --exclude e2e` — must be green
