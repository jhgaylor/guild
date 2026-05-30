# G9 Slice 2 — Inbound Association + Operator UI Link

Repo: jhgaylor/guild. Branch: g9/slice-2-inbound-association.
TESTS REQUIRED. Read slack_controller.ex fully before editing.
Do NOT create scratch docs outside plan/g9-slice-2/.
GUARDRAIL: no compile:true/override:true or rebar3 hacks in mix.exs.

## Context from reading the codebase

### lib/guild_web/controllers/slack_controller.ex — key facts

- `dispatch_event/2` handles three clause patterns:
  1. `%{"type" => "url_verification", "challenge" => challenge}` → returns challenge
  2. `%{"type" => "event_callback", "event" => event}` → calls `record_slack_event/2` first (ADR 0016), then pattern-matches on `event`
  3. Catch-all → `record_slack_event/2` + 200

- The `reaction_added` / `stop_sign` case currently matches:
  ```elixir
  %{
    "type" => "reaction_added",
    "reaction" => "stop_sign",
    "item" => %{"type" => "message", "channel" => channel, "ts" => ts}
  }
  ```
  It builds `url = "slack://" <> channel <> "/" <> ts` then queries `Schema.Artifact` by url.

- `record_slack_event/2` always inserts an Event row with `thread_id: nil` — this must remain the audit path; we do NOT pass thread_id into it (ADR 0016 record-all). Thread_id association for message events is done separately.

- Existing imports: `import Ecto.Query, only: [from: 2]`, `alias Guild.{Repo, Schema}`

### lib/guild/schema/artifact.ex — key facts
- Fields relevant: `thread_id` (binary_id), `artifact_type` (string), `url` (string)
- Slack message artifacts have `artifact_type == "slack_message"` and `url` like `"slack://CHANNEL/TS"`

### lib/guild/schema/thread.ex — key facts
- Fields added in Slice 1: `slack_thread_ts` (string), `slack_channel` (string)
- These are set when the first `:pr_open` Slack post is made

### lib/guild/schema/event.ex — key facts
- Fields: `source`, `event_type`, `occurred_at`, `thread_id` (binary_id, nullable), `raw_payload`, `idempotency_key`
- `thread_id` can be nil (audit-only rows)

### lib/guild_web/live/thread_live.html.heex — key facts
- Info card is at lines 15–32, inside `<section class="info-card"><dl class="info-grid">...</dl></section>`
- The `</dl>` closes at line 31, `</section>` at line 32
- Insert the "Open in Slack" link INSIDE the `<dl>` after the last `</dd>` for "Updated" (line 30)

### test/guild_web/controllers/slack_controller_test.exs — key facts
- Uses `GuildWeb.ConnCase, async: false`
- Has `insert_thread/2` helper (anchor_type: "github_issue", anchor_id as string, state)
- Has `slack_events_conn/3` helper that signs JSON bodies and POSTs to `/slack/events`
- Existing `reaction_added` test seeds a thread + artifact with `url: "slack://C_CHAN_1/1234567890.123456"`

### test/guild_web/live/thread_live_test.exs — key facts
- Uses `GuildWeb.ConnCase` + `Phoenix.LiveViewTest`
- Has `with_auth/1` helper using `OPERATOR_USERNAME`/`OPERATOR_PASSWORD` env vars
- Uses `live(conn |> with_auth(), ~p"/threads/#{thread.id}")`

---

## 1. Extend Slack Events handler — lib/guild_web/controllers/slack_controller.ex

### Add private helper `resolve_work_thread/3`

```elixir
defp resolve_work_thread(channel, ts, thread_ts_opt) do
  url = "slack://" <> channel <> "/" <> ts

  # Strategy (a): artifact lookup by url
  case Repo.one(from a in Schema.Artifact,
         where: a.artifact_type == "slack_message" and a.url == ^url,
         limit: 1) do
    %Schema.Artifact{thread_id: thread_id} ->
      {:ok, thread_id}

    nil ->
      # Strategy (b): thread column lookup by ts
      case Repo.one(from t in Schema.Thread,
             where: t.slack_channel == ^channel and t.slack_thread_ts == ^ts,
             limit: 1) do
        %Schema.Thread{id: thread_id} ->
          {:ok, thread_id}

        nil ->
          # Strategy (c): thread column lookup by thread_ts_opt (parent ts)
          if thread_ts_opt do
            case Repo.one(from t in Schema.Thread,
                   where: t.slack_channel == ^channel and t.slack_thread_ts == ^thread_ts_opt,
                   limit: 1) do
              %Schema.Thread{id: thread_id} -> {:ok, thread_id}
              nil -> :not_found
            end
          else
            :not_found
          end
      end
  end
end
```

### Update `reaction_added` handling in `dispatch_event/2`

The existing pattern match for `reaction_added` / `stop_sign` is inside the `case event do` block in the `%{"type" => "event_callback", "event" => event}` clause.

Replace the current match:

```elixir
# BEFORE:
%{
  "type" => "reaction_added",
  "reaction" => "stop_sign",
  "item" => %{"type" => "message", "channel" => channel, "ts" => ts}
} ->
  url = "slack://" <> channel <> "/" <> ts

  case Repo.one(from a in Schema.Artifact, where: a.url == ^url, limit: 1) do
    nil ->
      :ok

    artifact ->
      case Guild.Control.hold(artifact.thread_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
      end
  end
```

With:

```elixir
# AFTER:
%{
  "type" => "reaction_added",
  "reaction" => "stop_sign",
  "item" => %{"type" => "message", "channel" => channel, "ts" => item_ts}
} ->
  item_thread_ts = get_in(event, ["item", "thread_ts"])

  case resolve_work_thread(channel, item_ts, item_thread_ts) do
    {:ok, thread_id} ->
      case Guild.Control.hold(thread_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
      end

    :not_found ->
      Logger.debug("SlackController.events: reaction_added stop_sign on non-Guild message, no-op")
      :ok
  end
```

### Update `message` event handling in `dispatch_event/2`

The `dispatch_event/2` for `event_callback` currently calls `record_slack_event/2` then runs a `case event do` block. After the `_ -> :ok` catch-all in that case, add message-event thread association logic.

Specifically, within the `%{"type" => "event_callback", "event" => event}` clause, after `record_slack_event(event_type, params)` is called, add handling for message events with `thread_ts` to associate the recorded Event with a work thread.

The full updated `event_callback` clause should look like:

```elixir
defp dispatch_event(conn, %{"type" => "event_callback", "event" => event} = params) do
  event_type = Map.get(event, "type", "unknown")

  # ADR 0016: every verified Slack event is recorded, including state-driving ones.
  record_slack_event(event_type, params)

  # Then optionally drive state: stop_sign reaction on a Guild-owned slack_message → hold.
  case event do
    %{
      "type" => "reaction_added",
      "reaction" => "stop_sign",
      "item" => %{"type" => "message", "channel" => channel, "ts" => item_ts}
    } ->
      item_thread_ts = get_in(event, ["item", "thread_ts"])

      case resolve_work_thread(channel, item_ts, item_thread_ts) do
        {:ok, thread_id} ->
          case Guild.Control.hold(thread_id) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
          end

        :not_found ->
          Logger.debug("SlackController.events: reaction_added stop_sign on non-Guild message, no-op")
          :ok
      end

    %{"type" => "message", "channel" => channel, "ts" => msg_ts} ->
      # For reply messages (thread_ts present), associate the already-inserted Event row
      # with the work thread by updating thread_id.
      case Map.get(event, "thread_ts") do
        nil ->
          # Top-level message — Event already inserted with thread_id nil, no further action
          :ok

        thread_ts ->
          case resolve_work_thread(channel, msg_ts, thread_ts) do
            {:ok, thread_id} ->
              # Update the most recently inserted slack.message Event for this channel/ts
              # to attach the resolved thread_id
              update_latest_slack_message_event_thread(channel, msg_ts, thread_id)

            :not_found ->
              :ok
          end
      end

    _ ->
      :ok
  end

  send_resp(conn, 200, "")
end
```

**IMPORTANT**: The `record_slack_event/2` function always inserts with `thread_id: nil`. For message replies, after inserting the audit row, we look up the thread and update the Event row's `thread_id`. Add this private helper:

```elixir
defp update_latest_slack_message_event_thread(channel, ts, thread_id) do
  # Find the most recently inserted slack.message Event that matches this channel/ts
  # via the raw_payload and update its thread_id
  key_fragment = "slack://#{channel}/#{ts}"

  case Repo.one(
    from e in Schema.Event,
    where: e.event_type == "slack.message" and is_nil(e.thread_id),
    order_by: [desc: e.id],
    limit: 1
  ) do
    nil ->
      :ok

    event ->
      event
      |> Schema.Event.changeset(%{thread_id: thread_id})
      |> Repo.update()
      |> case do
        {:ok, _} -> :ok
        {:error, cs} -> Logger.warning("SlackController.events: failed to update event thread_id: #{inspect(cs.errors)}")
      end
  end
end
```

**SIMPLER ALTERNATIVE** (preferred — avoids the fragile "find latest" approach):

Instead of inserting with nil then updating, modify `record_slack_event/2` to accept an optional `thread_id` parameter, OR handle message events with their thread association inline before calling `record_slack_event`. The cleanest approach:

For message events with `thread_ts`, call `resolve_work_thread` FIRST, then call a variant of `record_slack_event` that accepts the resolved `thread_id`.

**RECOMMENDED IMPLEMENTATION:**

Change `record_slack_event/2` to `record_slack_event/3` with `thread_id \\ nil`:

```elixir
defp record_slack_event(event_type, raw_payload, thread_id \\ nil) do
  attrs = %{
    source: "slack",
    event_type: "slack." <> event_type,
    occurred_at: DateTime.utc_now(),
    raw_payload: raw_payload,
    thread_id: thread_id,
    idempotency_key: "slack:#{event_type}:#{Ecto.UUID.generate()}"
  }

  changeset = %Schema.Event{} |> Schema.Event.changeset(attrs)

  case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
    {:ok, _} -> :ok
    {:error, cs} -> Logger.warning("SlackController.events: failed to insert event: #{inspect(cs.errors)}")
  end
end
```

And in the `event_callback` dispatch clause, for message events with `thread_ts`, resolve BEFORE recording:

```elixir
defp dispatch_event(conn, %{"type" => "event_callback", "event" => event} = params) do
  event_type = Map.get(event, "type", "unknown")

  # For message replies, resolve thread_id before recording (ADR 0016 + association).
  thread_id =
    case event do
      %{"type" => "message", "channel" => channel, "ts" => ts, "thread_ts" => thread_ts} ->
        case resolve_work_thread(channel, ts, thread_ts) do
          {:ok, tid} -> tid
          :not_found -> nil
        end

      _ ->
        nil
    end

  # ADR 0016: every verified Slack event is recorded, including state-driving ones.
  record_slack_event(event_type, params, thread_id)

  # Then optionally drive state.
  case event do
    %{
      "type" => "reaction_added",
      "reaction" => "stop_sign",
      "item" => %{"type" => "message", "channel" => channel, "ts" => item_ts}
    } ->
      item_thread_ts = get_in(event, ["item", "thread_ts"])

      case resolve_work_thread(channel, item_ts, item_thread_ts) do
        {:ok, thread_id} ->
          case Guild.Control.hold(thread_id) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.warning("SlackController.events: hold error: #{inspect(reason)}")
          end

        :not_found ->
          Logger.debug("SlackController.events: reaction_added stop_sign on non-Guild message, no-op")
          :ok
      end

    _ ->
      :ok
  end

  send_resp(conn, 200, "")
end
```

Note: The pattern `%{"type" => "message", "channel" => channel, "ts" => ts, "thread_ts" => thread_ts}` only matches when all four keys are present — so top-level messages (no `thread_ts`) naturally fall through to `_ -> nil`. This is the cleanest approach.

---

## 2. "Open in Slack" link — lib/guild_web/live/thread_live.html.heex

In the `<dl class="info-grid">` block, after the "Updated" `<dd>` (line 30), before `</dl>` (line 31), insert:

```heex
      <%= if @thread.slack_thread_ts do %>
        <dt>Slack</dt>
        <dd>
          <a href={"https://slack.com/app_redirect?channel=#{@thread.slack_channel}&message=#{@thread.slack_thread_ts}"}
             target="_blank" rel="noopener">Open in Slack</a>
        </dd>
      <% end %>
```

The exact insertion point — after line 30 (`<dd class="timestamp"><%= GuildWeb.Format.time(@thread.updated_at) %></dd>`) and before `</dl>` on line 31.

---

## 3. Tests

### test/guild_web/controllers/slack_controller_test.exs

Add a new `describe` block for the new association behaviors. Use the existing `insert_thread/2` helper, `slack_events_conn/3` helper, and `@test_secret`.

For seeding threads with `slack_channel`/`slack_thread_ts`, use `Thread.changeset/2` with those fields — they are in the castable fields list per `thread.ex`.

**Test A — reaction_added via artifact lookup (existing behavior, must still pass):**

The existing test at line 263 already covers this. Do NOT delete or modify it. The refactored `resolve_work_thread` must keep this working.

**Test B — reaction_added via thread column lookup (no artifact):**

```elixir
test "reaction_added stop_sign sets held via thread column when no artifact", %{conn: conn} do
  {:ok, thread} =
    %Thread{}
    |> Thread.changeset(%{
      anchor_type: "github_issue",
      anchor_id: "g9s2-b",
      state: "executing",
      slack_channel: "C123",
      slack_thread_ts: "333.444"
    })
    |> Repo.insert()

  body = %{
    "type" => "event_callback",
    "event" => %{
      "type" => "reaction_added",
      "reaction" => "stop_sign",
      "item" => %{
        "type" => "message",
        "channel" => "C123",
        "ts" => "333.444"
      }
    }
  }

  conn = slack_events_conn(conn, body)
  assert conn.status == 200
  assert Repo.get!(Thread, thread.id).held == true
end
```

**Test C — reaction_added on a REPLY via thread_ts:**

```elixir
test "reaction_added stop_sign on reply resolves via thread_ts (parent)", %{conn: conn} do
  {:ok, thread} =
    %Thread{}
    |> Thread.changeset(%{
      anchor_type: "github_issue",
      anchor_id: "g9s2-c",
      state: "executing",
      slack_channel: "C123",
      slack_thread_ts: "555.666"
    })
    |> Repo.insert()

  body = %{
    "type" => "event_callback",
    "event" => %{
      "type" => "reaction_added",
      "reaction" => "stop_sign",
      "item" => %{
        "type" => "message",
        "channel" => "C123",
        "ts" => "999.000",
        "thread_ts" => "555.666"
      }
    }
  }

  conn = slack_events_conn(conn, body)
  assert conn.status == 200
  assert Repo.get!(Thread, thread.id).held == true
end
```

**Test D — message reply associates to work thread:**

```elixir
test "message reply event associates to work thread via thread_ts", %{conn: conn} do
  {:ok, thread} =
    %Thread{}
    |> Thread.changeset(%{
      anchor_type: "github_issue",
      anchor_id: "g9s2-d",
      state: "executing",
      slack_channel: "C123",
      slack_thread_ts: "111.222"
    })
    |> Repo.insert()

  body = %{
    "type" => "event_callback",
    "event" => %{
      "type" => "message",
      "channel" => "C123",
      "ts" => "222.333",
      "thread_ts" => "111.222",
      "text" => "a reply"
    }
  }

  conn = slack_events_conn(conn, body)
  assert conn.status == 200

  event = Repo.one(from e in Event,
    where: e.event_type == "slack.message" and e.thread_id == ^thread.id)
  assert event != nil
end
```

**Test E — top-level message (no thread_ts) → Event with thread_id nil:**

```elixir
test "top-level message event inserts Event with thread_id nil", %{conn: conn} do
  body = %{
    "type" => "event_callback",
    "event" => %{
      "type" => "message",
      "channel" => "C123",
      "ts" => "444.555",
      "text" => "top-level message"
    }
  }

  conn = slack_events_conn(conn, body)
  assert conn.status == 200

  event = Repo.one(from e in Event,
    where: e.event_type == "slack.message" and is_nil(e.thread_id))
  assert event != nil
end
```

### test/guild_web/live/thread_live_test.exs

Add at the end of the file (before the closing `end`):

**Test F — "Open in Slack" link present when slack_thread_ts set:**

```elixir
test "shows Open in Slack link when slack_thread_ts is set", %{conn: conn} do
  {:ok, thread} =
    %Guild.Schema.Thread{}
    |> Guild.Schema.Thread.changeset(%{
      anchor_type: "github_issue",
      anchor_id: "slack-link-test-1",
      state: "executing",
      slack_channel: "C123",
      slack_thread_ts: "111.222"
    })
    |> Guild.Repo.insert()

  {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
  assert html =~ "app_redirect?channel=C123&message=111.222"
end
```

**Test G — link absent when slack_thread_ts nil:**

```elixir
test "does not show Open in Slack link when slack_thread_ts is nil", %{conn: conn} do
  {:ok, thread} =
    %Guild.Schema.Thread{}
    |> Guild.Schema.Thread.changeset(%{
      anchor_type: "github_issue",
      anchor_id: "slack-link-test-2",
      state: "executing"
    })
    |> Guild.Repo.insert()

  {:ok, _view, html} = conn |> with_auth() |> live(~p"/threads/#{thread.id}")
  refute html =~ "Open in Slack"
end
```

---

## Summary of changes

| File | Change |
|------|--------|
| `lib/guild_web/controllers/slack_controller.ex` | Add `resolve_work_thread/3`; update `record_slack_event/2` → `/3` with optional `thread_id`; update `reaction_added` dispatch to use `resolve_work_thread`; update `event_callback` clause to resolve thread_id for message replies before recording |
| `lib/guild_web/live/thread_live.html.heex` | Add "Open in Slack" conditional link inside `info-card` dl, after the Updated row |
| `test/guild_web/controllers/slack_controller_test.exs` | Add Tests B, C, D, E (Test A already exists and must keep passing) |
| `test/guild_web/live/thread_live_test.exs` | Add Tests F and G |

## Verification

Run `mix test --exclude e2e` — must be green before opening the PR.
