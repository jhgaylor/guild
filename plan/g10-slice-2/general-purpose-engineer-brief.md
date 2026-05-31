# G10 Slice 2 — Classifier with Dry-Run

Repo: jhgaylor/guild. Branch: g10/slice-2-classifier-dry-run.
Base off: `main` (b85104b — Slice 1 merged + ADR 0017 accepted).
TESTS REQUIRED. Read existing files before editing. No scratch docs outside plan/g10-slice-2/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

Goal: every top-level message in an enabled channel produces a classification
Event with verdict, confidence, and reasoning. Nothing acts on it yet
(dry-run default-on). Self-loop guard prevents Guild from classifying its own
output.

---

## 1. Migration — `priv/repo/migrations/20260531200001_create_slack_inbox_events.exs`

```elixir
defmodule Guild.Repo.Migrations.CreateSlackInboxEvents do
  use Ecto.Migration

  def change do
    create table(:slack_inbox_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false         # Slack event_id — dedup key
      add :channel_id, :string, null: false
      add :user_id, :string, null: false
      add :user_display_name, :string
      add :message_ts, :string, null: false
      add :message_text, :text                    # truncated to 2000 chars
      add :verdict, :string                       # "new_work" | "refers_to_existing" | "noise" | "skipped" | "failed"
      add :confidence, :float
      add :reasoning, :text
      add :thread_id, :binary_id, null: true      # FK→threads.id; dual-purpose: see ADR 0017
      add :action_taken, :string, null: true      # nil | "issue_created" | "reference_reply_posted" | "dry_run" | "noise"
      add :github_issue_url, :string, null: true
      add :override_verdict, :string, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:slack_inbox_events, [:event_id])
    create index(:slack_inbox_events, [:channel_id, :user_id, :inserted_at])
    create index(:slack_inbox_events, [:thread_id])
  end
end
```

Notes:
- `thread_id` is NOT a foreign key constraint (threads can be deleted; keep it loose, same pattern as rest of schema).
- `inserted_at` only — no `updated_at`. Use `timestamps(updated_at: false)` (check Ecto docs for exact syntax — may be `timestamps(type: :utc_datetime_usec) |> Keyword.delete(:updated_at)` or simply omit by defining columns explicitly with `add :inserted_at, :utc_datetime_usec`). **Simplest approach**: just use `add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")` and skip `timestamps/1` entirely, OR use `timestamps(type: :utc_datetime_usec)` and add `updated_at` (accepting the extra column — fine for G10). Pick whichever compiles cleanly.

---

## 2. Schema — `lib/guild/schema/slack_inbox_event.ex`

```elixir
defmodule Guild.Schema.SlackInboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "slack_inbox_events" do
    field :event_id, :string
    field :channel_id, :string
    field :user_id, :string
    field :user_display_name, :string
    field :message_ts, :string
    field :message_text, :string
    field :verdict, :string
    field :confidence, :float
    field :reasoning, :string
    field :thread_id, :binary_id
    field :action_taken, :string
    field :github_issue_url, :string
    field :override_verdict, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id, :channel_id, :user_id, :user_display_name,
      :message_ts, :message_text, :verdict, :confidence, :reasoning,
      :thread_id, :action_taken, :github_issue_url, :override_verdict
    ])
    |> validate_required([:event_id, :channel_id, :user_id, :message_ts])
    |> unique_constraint(:event_id)
  end
end
```

---

## 3. OpenRouter HTTP client — `lib/guild/llm/open_router.ex`

New file. Uses HTTPoison (already in deps — same as `Guild.Adapters.Slack`).

```elixir
defmodule Guild.LLM.OpenRouter do
  @moduledoc """
  Stateless HTTP client for OpenRouter's chat completions API.
  Used for one-shot LLM classification tasks (ADR 0017).
  """

  require Logger

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o-mini"
  @timeout_ms 10_000

  @doc """
  Send a single-turn prompt and return the model's text response.

  Returns {:ok, text} on success or {:error, reason} on failure.
  """
  def complete(prompt, opts \\ []) do
    api_key = Application.get_env(:guild, :openrouter_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      model = Keyword.get(opts, :model) ||
        Application.get_env(:guild, :openrouter_classifier_model, @default_model)

      url = Application.get_env(:guild, :openrouter_api_url, @default_url)

      body = Jason.encode!(%{
        model: model,
        messages: [%{role: "user", content: prompt}],
        max_tokens: 300,
        temperature: 0.1
      })

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"HTTP-Referer", "https://guild.inevitable.fyi"}
      ]

      case HTTPoison.post(url, body, headers, recv_timeout: @timeout_ms, timeout: @timeout_ms) do
        {:ok, %{status_code: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]}} ->
              {:ok, text}
            {:ok, other} ->
              Logger.warning("OpenRouter: unexpected response shape: #{inspect(other)}")
              {:error, {:unexpected_shape, other}}
            {:error, _} ->
              {:error, :invalid_json}
          end

        {:ok, %{status_code: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status_code: status}} when status >= 500 ->
          {:error, {:server_error, status}}

        {:ok, %{status_code: status}} ->
          {:error, {:http_error, status}}

        {:error, %HTTPoison.Error{reason: :timeout}} ->
          {:error, :timeout}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, {:transport_error, reason}}
      end
    end
  end
end
```

Config note (for step 6 below): wire `openrouter_api_url` as an app env so tests can point it at Bypass. Same pattern as `:slack_api_url` in the Slack adapter.

---

## 4. Classifier — `lib/guild/slack_inbox.ex`

New file.

```elixir
defmodule Guild.SlackInbox do
  @moduledoc """
  LLM-based classifier for inbound Slack messages (ADR 0017).
  """

  require Logger

  @doc """
  Classify a top-level Slack message.

  Input map:
    %{
      message: "the message text",
      channel_id: "C012AB3CD",
      channel_name: "guild",        # used in prompt; may be same as channel_id if name unavailable
      user_display_name: "Alice",
      default_repo: "owner/repo",   # or nil
      open_threads: [               # list of maps
        %{id: "uuid", anchor_id: "repo#N", summary: "one-line summary", state: "executing", updated_at: ~U[...]}
      ]
    }

  Returns {:ok, %{verdict:, confidence:, reasoning:, thread_id:}} or {:error, reason}.
  `thread_id` is the matched thread UUID for :refers_to_existing, nil otherwise.
  """
  def classify(%{message: msg, channel_id: ch_id, channel_name: ch_name,
                 user_display_name: display_name, default_repo: default_repo,
                 open_threads: threads}) do
    prompt = build_prompt(msg, ch_name || ch_id, default_repo, display_name, threads)

    case Guild.LLM.OpenRouter.complete(prompt) do
      {:ok, text} ->
        parse_classification(text)

      {:error, :no_api_key} ->
        {:error, :no_api_key}

      {:error, reason} ->
        Logger.warning("SlackInbox.classify: OpenRouter error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(message, channel_name, default_repo, user_display_name, open_threads) do
    threads_text =
      if Enum.empty?(open_threads) do
        "(none)"
      else
        open_threads
        |> Enum.take(20)
        |> Enum.map(fn t ->
          "- [#{t.id}] #{t.anchor_id}: #{t.summary} (#{t.state})"
        end)
        |> Enum.join("\n")
      end

    repo_text = default_repo || "not configured"

    """
    You are a work-routing assistant for an autonomous software engineering bot called Guild.
    Guild watches a Slack channel and decides whether each new top-level message represents:
    - "new_work": a request for Guild to perform a software task (fix a bug, add a feature, update docs, etc.)
    - "refers_to_existing": a message referencing work that Guild is already doing or has done
    - "noise": casual conversation, questions not directed at Guild, announcements, etc.

    Channel: ##{channel_name} | Repo: #{repo_text} | User: #{user_display_name}

    Message:
    \"\"\"
    #{String.slice(message, 0, 2000)}
    \"\"\"

    Currently open work threads (most recent first):
    #{threads_text}

    Return ONLY valid JSON. No markdown. No commentary before or after the JSON object.
    {
      "verdict": "new_work" | "refers_to_existing" | "noise",
      "confidence": <float 0.0-1.0>,
      "reasoning": "<200 chars or less explaining your verdict>",
      "matched_thread_id": "<thread UUID if refers_to_existing, else null>"
    }
    """
  end

  defp parse_classification(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, %{"verdict" => verdict, "confidence" => confidence, "reasoning" => reasoning} = decoded}
      when verdict in ["new_work", "refers_to_existing", "noise"] and is_float(confidence) ->
        thread_id = Map.get(decoded, "matched_thread_id")
        {:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: thread_id}}

      {:ok, %{"verdict" => verdict, "confidence" => confidence, "reasoning" => reasoning} = decoded}
      when verdict in ["new_work", "refers_to_existing", "noise"] and is_integer(confidence) ->
        # Handle integer confidence (e.g. 1 instead of 1.0)
        thread_id = Map.get(decoded, "matched_thread_id")
        {:ok, %{verdict: verdict, confidence: confidence / 1.0, reasoning: reasoning, thread_id: thread_id}}

      {:ok, other} ->
        Logger.warning("SlackInbox.classify: unexpected JSON shape: #{inspect(other)}")
        {:ok, %{verdict: "noise", confidence: 0.0,
                reasoning: "Malformed classifier response: #{String.slice(text, 0, 200)}",
                thread_id: nil}}

      {:error, _} ->
        Logger.warning("SlackInbox.classify: non-JSON response: #{String.slice(text, 0, 200)}")
        {:ok, %{verdict: "noise", confidence: 0.0,
                reasoning: "Non-JSON classifier response: #{String.slice(text, 0, 200)}",
                thread_id: nil}}
    end
  end
end
```

---

## 5. Oban Worker — `lib/guild/workers/slack_inbox_worker.ex`

New file.

```elixir
defmodule Guild.Workers.SlackInboxWorker do
  @moduledoc """
  Oban worker that classifies a top-level Slack message (ADR 0017).
  Queue: :slack_inbox, max_attempts: 2, unique on event_id.
  """

  use Oban.Worker,
    queue: :slack_inbox,
    max_attempts: 2,
    unique: [fields: [:args], keys: [:event_id], period: 300]

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Guild.{Repo, Schema}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "event_id" => event_id,
    "channel_id" => channel_id,
    "user_id" => user_id,
    "user_display_name" => user_display_name,
    "message_ts" => message_ts,
    "message_text" => message_text
  }}) do
    bot_user_id = Application.get_env(:guild, :slack_bot_user_id)

    # --- Prefilter (skip + no row) ---
    # 1. Bot message subtype
    # 2. Known bot user_id (belt-and-suspenders; degrades to subtype-only if absent)
    # 3. Message too short
    # 4. Slash command
    cond do
      String.starts_with?(user_id, "B") ->
        # Slack bot user IDs start with "B" — but this is heuristic; rely on bot_user_id match below
        # Actually: subtype filtering happens before enqueue. This is user_id check.
        :ok

      not is_nil(bot_user_id) and bot_user_id != "" and user_id == bot_user_id ->
        Logger.debug("SlackInboxWorker: skipping bot's own message (user_id match)")
        :ok

      String.length(String.trim(message_text)) < 10 ->
        Logger.debug("SlackInboxWorker: skipping short message")
        :ok

      String.starts_with?(String.trim(message_text), "/") ->
        Logger.debug("SlackInboxWorker: skipping slash command")
        :ok

      true ->
        run_classification(event_id, channel_id, user_id, user_display_name, message_ts, message_text)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_classification(event_id, channel_id, user_id, user_display_name, message_ts, message_text) do
    # --- Rate limit (inside worker, before OpenRouter call) ---
    # 1 classification per (user_id, channel_id) per 60s — see ADR 0017.
    sixty_seconds_ago = DateTime.add(DateTime.utc_now(), -60, :second)

    rate_limited? =
      Repo.exists?(
        from e in Schema.SlackInboxEvent,
          where:
            e.channel_id == ^channel_id and
            e.user_id == ^user_id and
            e.inserted_at > ^sixty_seconds_ago
      )

    if rate_limited? do
      Logger.debug("SlackInboxWorker: rate limit hit for user #{user_id} in #{channel_id}")
      :ok
    else
      do_classify(event_id, channel_id, user_id, user_display_name, message_ts, message_text)
    end
  end

  defp do_classify(event_id, channel_id, user_id, user_display_name, message_ts, message_text) do
    # Load channel config for default_repo
    channel = Repo.get(Schema.SlackChannel, channel_id)
    default_repo = channel && channel.default_repo

    # Load open threads for classifier context (20 most-recently-updated)
    open_states = ["noticed", "claimed", "executing", "pr_open"]
    open_threads =
      Repo.all(
        from t in Schema.Thread,
          where: t.state in ^open_states,
          order_by: [desc: t.updated_at],
          limit: 20,
          select: %{
            id: t.id,
            anchor_id: t.anchor_id,
            summary: t.anchor_id,   # anchor_id is "repo#N" — used as one-line summary
            state: t.state,
            updated_at: t.updated_at
          }
      )

    # Classify
    result =
      Guild.SlackInbox.classify(%{
        message: message_text,
        channel_id: channel_id,
        channel_name: channel_id,   # channel name not available without Slack API call; use ID
        user_display_name: user_display_name || user_id,
        default_repo: default_repo,
        open_threads: open_threads
      })

    case result do
      {:ok, %{verdict: verdict, confidence: confidence, reasoning: reasoning, thread_id: matched_thread_id}} ->
        dry_run? = System.get_env("SLACK_INBOX_DRY_RUN", "true") == "true"

        action_taken =
          if dry_run? do
            "dry_run"
          else
            # Slice 3 will add real actions here; for now stub as "noise"
            "noise"
          end

        # Insert slack_inbox_events row
        attrs = %{
          event_id: event_id,
          channel_id: channel_id,
          user_id: user_id,
          user_display_name: user_display_name,
          message_ts: message_ts,
          message_text: String.slice(message_text, 0, 2000),
          verdict: verdict,
          confidence: confidence,
          reasoning: String.slice(reasoning || "", 0, 500),
          thread_id: if(verdict == "refers_to_existing", do: matched_thread_id, else: nil),
          action_taken: action_taken,
          github_issue_url: nil
        }

        changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)

        case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id) do
          {:ok, _} -> :ok
          {:error, cs} ->
            Logger.warning("SlackInboxWorker: failed to insert slack_inbox_event: #{inspect(cs.errors)}")
            {:error, :db_insert_failed}
        end

      {:error, :no_api_key} ->
        Logger.warning("SlackInboxWorker: OPENROUTER_API_KEY not set, skipping")
        # Don't insert a failed row — key absence is a config issue, not a message issue
        :ok

      {:error, reason} ->
        # Record a failed row so it shows in /admin/slack-inbox
        attrs = %{
          event_id: event_id,
          channel_id: channel_id,
          user_id: user_id,
          user_display_name: user_display_name,
          message_ts: message_ts,
          message_text: String.slice(message_text, 0, 2000),
          verdict: "failed",
          confidence: 0.0,
          reasoning: "Classification error: #{inspect(reason)}",
          thread_id: nil,
          action_taken: nil
        }

        changeset = Schema.SlackInboxEvent.changeset(%Schema.SlackInboxEvent{}, attrs)
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id)

        # Return error so Oban retries (max_attempts: 2)
        {:error, reason}
    end
  end
end
```

**Important prefilter note:** The `subtype == "bot_message"` filter happens at
the Events handler (step 7 below) before the job is enqueued. The worker only
needs to check `user_id == bot_user_id` (identity guard). The cond block above
is simplified — the first arm checking `String.starts_with?(user_id, "B")` is
NOT reliable (user IDs starting with B are just bots in general but that's not
guaranteed). Remove that arm and rely only on the `bot_user_id` match + the
handler-level subtype filter. The correct cond in the worker is:

```elixir
cond do
  not is_nil(bot_user_id) and bot_user_id != "" and user_id == bot_user_id ->
    Logger.debug("SlackInboxWorker: skipping bot's own message (user_id match)")
    :ok
  String.length(String.trim(message_text)) < 10 ->
    :ok
  String.starts_with?(String.trim(message_text), "/") ->
    :ok
  true ->
    run_classification(...)
end
```

---

## 6. Config — `config/config.exs` + `config/runtime.exs`

### `config/config.exs` — add `:slack_inbox` to Oban queues

Find the existing `config :guild, Oban` block:
```elixir
config :guild, Oban,
  repo: Guild.Repo,
  queues: [claims: 10],
  ...
```

Change to:
```elixir
config :guild, Oban,
  repo: Guild.Repo,
  queues: [claims: 10, slack_inbox: 5],
  ...
```

### `config/runtime.exs` — add OpenRouter + inbox env vars

After the existing Fountain config block, add (outside the `if config_env() == :prod do` block, same level as the Fountain block):

```elixir
# OpenRouter — stateless LLM classification (ADR 0017)
config :guild,
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  openrouter_classifier_model: System.get_env("OPENROUTER_CLASSIFIER_MODEL", "openai/gpt-4o-mini"),
  slack_bot_user_id: System.get_env("SLACK_BOT_USER_ID")
```

Note: `SLACK_INBOX_DRY_RUN` and `SLACK_INBOX_CONFIDENCE_THRESHOLD` are read
directly from `System.get_env/2` inside the worker/action code (not wired into
app env) — they can change per-deploy without a code touch.

Also note: `openrouter_api_url` is NOT wired in runtime.exs (it defaults to
the OpenRouter URL in `Guild.LLM.OpenRouter` but can be overridden in test
setup via `Application.put_env` — same pattern as `:slack_api_url`).

### `config/test.exs` — log warning about SLACK_BOT_USER_ID at startup

Add nothing to test.exs for this. The startup warning for missing
`SLACK_BOT_USER_ID` (per ADR 0017) is logged in `Guild.Application.start/2`:

In `lib/guild/application.ex`, inside `start/2`, after children list is built
but before `Supervisor.start_link/2`, add:

```elixir
bot_user_id = Application.get_env(:guild, :slack_bot_user_id)
if is_nil(bot_user_id) or bot_user_id == "" do
  require Logger
  Logger.warning("SLACK_BOT_USER_ID not set — self-loop guard degrades to subtype-only (ADR 0017)")
end
```

---

## 7. Events handler wiring — `lib/guild_web/controllers/slack_controller.ex`

The Slice 1 gate already runs. Find the `should_process` block and the
`if should_process do` guard in `dispatch_event/2` (the `"event_callback"` clause).

Currently the `if should_process do` block only handles `reaction_added`. Extend
it to also enqueue `SlackInboxWorker` for top-level enabled-channel messages.

**Replace** the `if should_process do` block with:

```elixir
if should_process do
  # Enqueue SlackInboxWorker for top-level messages in enabled channels.
  # Prefilter: skip bot_message subtypes here (before enqueue saves DB roundtrip).
  case event do
    %{"type" => "message", "channel" => ch_id, "user" => uid, "ts" => ts}
    when not is_map_key(event, "thread_ts") ->
      subtype = Map.get(event, "subtype")
      if subtype != "bot_message" do
        job_args = %{
          event_id: Map.get(event, "event_id") || Map.get(params, "event_id") || "#{ch_id}:#{ts}",
          channel_id: ch_id,
          user_id: uid,
          user_display_name: Map.get(event, "user_profile", %{}) |> Map.get("display_name") ||
                             Map.get(event, "username") || uid,
          message_ts: ts,
          message_text: String.slice(Map.get(event, "text", ""), 0, 2000)
        }

        case Guild.Workers.SlackInboxWorker.new(job_args) |> Oban.insert() do
          {:ok, _job} -> :ok
          {:error, reason} ->
            Logger.warning("SlackController: failed to enqueue SlackInboxWorker: #{inspect(reason)}")
        end
      end

    %{"type" => "reaction_added", "reaction" => "stop_sign", "item" => %{"type" => "message"}} ->
      case thread_id do
        nil ->
          Logger.debug("SlackController.events: reaction_added stop_sign on non-Guild message, no-op")
          :ok
        tid ->
          case Guild.Control.hold(tid) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
          end
      end

    _ ->
      :ok
  end
end
```

**Read the actual current file** before editing — the existing `if should_process do` block may have slightly different indentation or structure. The key change: turn the single `case event do` inside the `if` into one that handles both the message-enqueue path and the reaction-added path.

`event_id`: Slack event callbacks include `event["event_ts"]` and an outer
`params["event_id"]`. Prefer `Map.get(event, "event_id") || Map.get(params, "event_id") || "#{ch_id}:#{ts}"` as the dedup key. Check actual Slack payload shape — the outer `event_callback` envelope has `event_id`, not the inner event map.

---

## 8. Integration status — OpenRouter card

### `lib/guild_web/controllers/admin_controller.ex`

Add `openrouter_status()` private helper (after `fountain_status`):

```elixir
defp openrouter_status do
  api_key = Application.get_env(:guild, :openrouter_api_key)
  model = Application.get_env(:guild, :openrouter_classifier_model, "openai/gpt-4o-mini")
  status = if present?(api_key), do: :ready, else: :unconfigured

  {status, %{api_key_set: present?(api_key), model: model}}
end
```

Update `integrations/2` action to include `openrouter`:

```elixir
def integrations(conn, _params) do
  github = github_status()
  slack = slack_status()
  linear = linear_status()
  fountain = fountain_status()
  openrouter = openrouter_status()

  render(conn, :integrations,
    github: github,
    slack: slack,
    linear: linear,
    fountain: fountain,
    openrouter: openrouter
  )
end
```

### `lib/guild_web/controllers/admin_html/integrations.html.heex`

Add OpenRouter card after the Fountain card (before the closing `</div></div>`):

```html
    <%!-- OpenRouter card --%>
    <% {openrouter_status, openrouter_details} = @openrouter %>
    <div class={"integration-card integration-card--#{openrouter_status}"}>
      <h2>OpenRouter</h2>
      <p class="integration-status">
        Status: <strong><%= status_label(openrouter_status) %></strong>
      </p>
      <ul class="integration-details">
        <li>API Key: <%= if openrouter_details.api_key_set, do: "set", else: "not set" %></li>
        <li>Classifier Model: <%= openrouter_details.model %></li>
      </ul>
    </div>
```

---

## 9. `k8s/secret.yaml` — add new env vars

The file is documentation/template only — do NOT kubectl apply it. Add these
entries to the `data:` section (same base64 placeholder `Y2hhbmdlbWU=`):

```yaml
  # OpenRouter — stateless LLM classification (ADR 0017)
  OPENROUTER_API_KEY: Y2hhbmdlbWU=
  OPENROUTER_CLASSIFIER_MODEL: Y2hhbmdlbWU=
  # Slack inbox — classifier behaviour
  SLACK_INBOX_DRY_RUN: Y2hhbmdlbWU=
  SLACK_INBOX_CONFIDENCE_THRESHOLD: Y2hhbmdlbWU=
  SLACK_BOT_USER_ID: Y2hhbmdlbWU=
```

---

## 10. Tests

### `test/guild/llm/open_router_test.exs`

New file. Uses Bypass.

```elixir
defmodule Guild.LLM.OpenRouterTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :openrouter_api_key, "test-key")
    Application.put_env(:guild, :openrouter_api_url, "http://localhost:#{bypass.port}/v1/chat/completions")
    on_exit(fn ->
      Application.delete_env(:guild, :openrouter_api_key)
      Application.delete_env(:guild, :openrouter_api_url)
    end)
    {:ok, bypass: bypass}
  end

  test "returns {:ok, text} on success", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"hello"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, "hello"} = Guild.LLM.OpenRouter.complete("test prompt")
  end

  test "returns {:error, :no_api_key} when key absent" do
    Application.delete_env(:guild, :openrouter_api_key)
    assert {:error, :no_api_key} = Guild.LLM.OpenRouter.complete("test")
  end

  test "returns {:error, :unauthorized} on 401", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
    end)
    assert {:error, :unauthorized} = Guild.LLM.OpenRouter.complete("test")
  end

  test "returns {:error, {:server_error, 500}} on 500", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 500, "oops")
    end)
    assert {:error, {:server_error, 500}} = Guild.LLM.OpenRouter.complete("test")
  end
end
```

### `test/guild/slack_inbox_test.exs`

New file. Unit test for `classify/1` with mocked OpenRouter.

```elixir
defmodule Guild.SlackInboxTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :openrouter_api_key, "test-key")
    Application.put_env(:guild, :openrouter_api_url, "http://localhost:#{bypass.port}/v1/chat/completions")
    on_exit(fn ->
      Application.delete_env(:guild, :openrouter_api_key)
      Application.delete_env(:guild, :openrouter_api_url)
    end)
    {:ok, bypass: bypass}
  end

  defp input(overrides \\ %{}) do
    Map.merge(%{
      message: "can you fix the login bug?",
      channel_id: "C123",
      channel_name: "guild",
      user_display_name: "Alice",
      default_repo: "owner/repo",
      open_threads: []
    }, overrides)
  end

  test "returns :new_work on valid classifier response", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"{\"verdict\":\"new_work\",\"confidence\":0.95,\"reasoning\":\"direct task request\",\"matched_thread_id\":null}"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "new_work", confidence: 0.95, thread_id: nil}} = Guild.SlackInbox.classify(input())
  end

  test "returns :noise with 0.0 confidence on malformed JSON", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"not json at all"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.0}} = Guild.SlackInbox.classify(input())
  end

  test "returns :noise with 0.0 confidence on wrong JSON shape", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = ~s({"choices":[{"message":{"content":"{\"foo\":\"bar\"}"}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
    assert {:ok, %{verdict: "noise", confidence: 0.0}} = Guild.SlackInbox.classify(input())
  end
end
```

### `test/guild/workers/slack_inbox_worker_test.exs`

New file. Uses `DataCase` (DB access) + Bypass.

```elixir
defmodule Guild.Workers.SlackInboxWorkerTest do
  use Guild.DataCase, async: false

  alias Guild.{Repo, Schema}

  @moduletag :capture_log

  setup do
    bypass = Bypass.open()
    Application.put_env(:guild, :openrouter_api_key, "test-key")
    Application.put_env(:guild, :openrouter_api_url, "http://localhost:#{bypass.port}/v1/chat/completions")
    Application.delete_env(:guild, :slack_bot_user_id)

    # Insert an enabled slack_channel so the worker can load it
    {:ok, _} = Repo.insert(%Schema.SlackChannel{channel_id: "C_TEST", enabled: true, default_repo: "owner/repo"})

    on_exit(fn ->
      Application.delete_env(:guild, :openrouter_api_key)
      Application.delete_env(:guild, :openrouter_api_url)
    end)

    {:ok, bypass: bypass}
  end

  defp job_args(overrides \\ %{}) do
    Map.merge(%{
      "event_id" => "evt_#{System.unique_integer([:positive])}",
      "channel_id" => "C_TEST",
      "user_id" => "U123",
      "user_display_name" => "Alice",
      "message_ts" => "1234567890.000001",
      "message_text" => "can you fix the login bug please?"
    }, overrides)
  end

  defp mock_openrouter(bypass, verdict, confidence \\ 0.95) do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      json = Jason.encode!(%{
        verdict: verdict,
        confidence: confidence,
        reasoning: "test reasoning",
        matched_thread_id: nil
      })
      body = Jason.encode!(%{choices: [%{message: %{content: json}}]})
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  describe "perform/1 — happy path dry-run" do
    test "inserts slack_inbox_events row with action_taken: dry_run", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      mock_openrouter(bypass, "new_work")

      args = job_args()
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)

      event = Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == ^args["event_id"])
      assert event.verdict == "new_work"
      assert event.confidence == 0.95
      assert event.action_taken == "dry_run"
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
    end
  end

  describe "perform/1 — prefilter" do
    test "skips messages shorter than 10 chars (no DB row inserted)" do
      args = job_args(%{"message_text" => "hi", "event_id" => "evt_short"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_short")
    end

    test "skips slash commands (no DB row inserted)" do
      args = job_args(%{"message_text" => "/deploy now", "event_id" => "evt_slash"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_slash")
    end

    test "skips bot's own messages when SLACK_BOT_USER_ID matches" do
      Application.put_env(:guild, :slack_bot_user_id, "U_BOT")
      args = job_args(%{"user_id" => "U_BOT", "event_id" => "evt_bot"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_bot")
    end
  end

  describe "perform/1 — rate limit" do
    test "skips second message from same user in 60s", %{bypass: bypass} do
      System.put_env("SLACK_INBOX_DRY_RUN", "true")
      mock_openrouter(bypass, "noise")

      # First message — should go through
      args1 = job_args(%{"event_id" => "evt_rl_1"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args1)
      assert Repo.get_by(Schema.SlackInboxEvent, event_id: "evt_rl_1") != nil

      # Second message from same user in same channel — should be rate-limited (no row)
      args2 = job_args(%{"event_id" => "evt_rl_2"})
      # Bypass should NOT receive a second OpenRouter call
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args2)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_rl_2")
    after
      System.delete_env("SLACK_INBOX_DRY_RUN")
    end
  end

  describe "perform/1 — no API key" do
    test "returns :ok without inserting row when OPENROUTER_API_KEY absent" do
      Application.delete_env(:guild, :openrouter_api_key)
      args = job_args(%{"event_id" => "evt_nokey"})
      assert :ok = perform_job(Guild.Workers.SlackInboxWorker, args)
      assert nil == Repo.one(from e in Schema.SlackInboxEvent, where: e.event_id == "evt_nokey")
    end
  end
end
```

**`perform_job/2` helper:** This is Oban's test helper. Check if your version
of `oban` (check `mix.exs`) exports `Oban.Testing.perform_job/2` or if you
need to call the worker directly:

```elixir
# Option A — if Oban.Testing.perform_job is available (Oban >= 2.11):
use Oban.Testing, repo: Guild.Repo
# then call: perform_job(Guild.Workers.SlackInboxWorker, args)

# Option B — if not, call directly:
args_struct = %Oban.Job{args: args}
Guild.Workers.SlackInboxWorker.perform(args_struct)
```

Look at how `ClaimWorker` tests (if any exist in `test/guild/workers/`) handle
this. If there are no worker tests, use Option B.

### Admin integrations test addition — `test/guild_web/controllers/admin_controller_test.exs`

In the existing `describe "GET /admin/integrations"` block, add one assertion:

```elixir
test "renders OpenRouter card", %{conn: conn} do
  conn = conn |> with_auth() |> get(~p"/admin/integrations")
  assert html_response(conn, 200) =~ "OpenRouter"
end
```

---

## Implementation order

1. Migration → verify `mix ecto.migrate` runs clean
2. Schema module (`SlackInboxEvent`)
3. `Guild.LLM.OpenRouter` + its test
4. `Guild.SlackInbox` + its test
5. Oban queue config (add `:slack_inbox` to `config.exs`)
6. Runtime config (OpenRouter env vars in `runtime.exs`)
7. `Guild.Workers.SlackInboxWorker` + its test
8. Application startup warning (`application.ex`)
9. Events handler wiring (`slack_controller.ex`)
10. Admin integrations (controller helper + template card)
11. `k8s/secret.yaml` additions
12. `mix test --exclude e2e` — all green before opening PR

## PR

Open PR against `main`. Title: `feat(g10/s2): classifier with dry-run (SlackInboxWorker + OpenRouter)`. Request review from jhgaylor.

Do not modify `ROADMAP.md` — the orchestrator handles that.
