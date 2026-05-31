defmodule GuildWeb.SlackControllerTest do
  use GuildWeb.ConnCase, async: false

  import Ecto.Query
  alias Guild.Repo
  alias Guild.Schema.{Thread, Artifact, Event}

  @test_secret "test_slack_signing_secret"

  setup do
    Application.put_env(:guild, :slack_signing_secret, @test_secret)
    on_exit(fn -> Application.delete_env(:guild, :slack_signing_secret) end)
    :ok
  end

  defp insert_thread(anchor_id, state \\ "executing") do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{anchor_type: "github_issue", anchor_id: to_string(anchor_id), state: state})
      |> Repo.insert()

    thread
  end

  defp slack_conn(conn, body_text, opts \\ []) do
    ts = to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @test_secret)

    base = "v0:#{ts}:#{body_text}"
    sig = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-slack-request-timestamp", ts)
    |> put_req_header("x-slack-signature", sig)
    |> post(~p"/slack/commands", body_text)
  end

  defp slack_interactions_conn(conn, payload_map, opts \\ []) do
    payload_json = Jason.encode!(payload_map)
    body_text = URI.encode_query(%{"payload" => payload_json})
    ts = to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @test_secret)

    base = "v0:#{ts}:#{body_text}"
    sig = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-slack-request-timestamp", ts)
    |> put_req_header("x-slack-signature", sig)
    |> post(~p"/slack/interactions", body_text)
  end

  describe "signature verification" do
    test "valid signature returns 200", %{conn: conn} do
      insert_thread(101)
      body = "command=%2Fguild&text=hold+101"
      conn = slack_conn(conn, body)
      assert conn.status == 200
    end

    test "invalid signature returns 403", %{conn: conn} do
      body = "command=%2Fguild&text=hold+200"
      conn = slack_conn(conn, body, secret: "wrong_secret")
      assert conn.status == 403
    end

    test "missing SLACK_SIGNING_SECRET returns 403", %{conn: conn} do
      Application.delete_env(:guild, :slack_signing_secret)
      body = "command=%2Fguild&text=hold+300"
      ts = to_string(System.system_time(:second))

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-slack-request-timestamp", ts)
        |> put_req_header("x-slack-signature", "v0=fake")
        |> post(~p"/slack/commands", body)

      assert conn.status == 403
    end

    test "stale timestamp (older than 5 min) returns 403", %{conn: conn} do
      stale_ts = System.system_time(:second) - 310
      body = "command=%2Fguild&text=hold+400"
      conn = slack_conn(conn, body, ts: stale_ts)
      assert conn.status == 403
    end
  end

  describe "hold command" do
    test "sets thread.held = true and returns ephemeral ack", %{conn: conn} do
      thread = insert_thread(500)
      body = "command=%2Fguild&text=hold+500"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end
  end

  describe "resume command" do
    test "sets thread.held = false and returns ephemeral ack", %{conn: conn} do
      thread = insert_thread(600)
      # Set held first
      Repo.update!(Thread.changeset(thread, %{held: true}))

      body = "command=%2Fguild&text=resume+600"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == false
    end
  end

  describe "abandon command" do
    test "transitions thread to abandoned and clears owner", %{conn: conn} do
      thread = insert_thread(700, "executing")
      Repo.update!(Thread.changeset(thread, %{owner: "worker-abc"}))

      body = "command=%2Fguild&text=abandon+700"
      conn = slack_conn(conn, body)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["response_type"] == "ephemeral"

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "abandoned"
      assert is_nil(updated.owner)
    end
  end

  describe "interactions endpoint" do
    test "valid guild_hold action sets thread.held = true", %{conn: conn} do
      thread = insert_thread(801)

      payload = %{
        "actions" => [
          %{"action_id" => "guild_hold", "value" => "801"}
        ]
      }

      conn = slack_interactions_conn(conn, payload)
      assert conn.status == 200

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true
    end

    test "valid guild_abandon action transitions thread to abandoned", %{conn: conn} do
      thread = insert_thread(802, "executing")

      payload = %{
        "actions" => [
          %{"action_id" => "guild_abandon", "value" => "802"}
        ]
      }

      conn = slack_interactions_conn(conn, payload)
      assert conn.status == 200

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == "abandoned"
    end

    test "guild_view action is a no-op, returns 200", %{conn: conn} do
      thread = insert_thread(803)

      payload = %{
        "actions" => [
          %{"action_id" => "guild_view", "value" => thread.id}
        ]
      }

      conn = slack_interactions_conn(conn, payload)
      assert conn.status == 200
    end

    test "invalid signature returns 403", %{conn: conn} do
      payload = %{"actions" => []}
      conn = slack_interactions_conn(conn, payload, secret: "wrong_secret")
      assert conn.status == 403
    end

    test "missing SLACK_SIGNING_SECRET returns 403", %{conn: conn} do
      Application.delete_env(:guild, :slack_signing_secret)

      payload_json = Jason.encode!(%{"actions" => []})
      body_text = URI.encode_query(%{"payload" => payload_json})
      ts = to_string(System.system_time(:second))

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-slack-request-timestamp", ts)
        |> put_req_header("x-slack-signature", "v0=fake")
        |> post(~p"/slack/interactions", body_text)

      assert conn.status == 403
    end
  end

  # Helper: build a signed Slack events POST
  defp slack_events_conn(conn, body_map, opts \\ []) do
    body_text = Jason.encode!(body_map)
    ts = to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @test_secret)

    base = "v0:#{ts}:#{body_text}"
    sig = "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-slack-request-timestamp", ts)
    |> put_req_header("x-slack-signature", sig)
    |> post(~p"/slack/events", body_text)
  end

  describe "events endpoint — signature verification" do
    test "invalid signature returns 403", %{conn: conn} do
      body = %{"type" => "url_verification", "challenge" => "abc123"}
      conn = slack_events_conn(conn, body, secret: "wrong_secret")
      assert conn.status == 403
    end

    test "missing SLACK_SIGNING_SECRET returns 403", %{conn: conn} do
      Application.delete_env(:guild, :slack_signing_secret)
      body_text = Jason.encode!(%{"type" => "url_verification", "challenge" => "abc"})
      ts = to_string(System.system_time(:second))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-request-timestamp", ts)
        |> put_req_header("x-slack-signature", "v0=fake")
        |> post(~p"/slack/events", body_text)

      assert conn.status == 403
    end
  end

  describe "events endpoint — url_verification" do
    test "valid sig + url_verification returns 200 with challenge value", %{conn: conn} do
      body = %{"type" => "url_verification", "challenge" => "my_challenge_token"}
      conn = slack_events_conn(conn, body)

      assert conn.status == 200
      assert conn.resp_body == "my_challenge_token"
    end
  end

  describe "events endpoint — reaction_added stop_sign" do
    test "valid sig + reaction_added stop_sign on slack_message artifact sets thread.held true", %{conn: conn} do
      thread = insert_thread(901)

      {:ok, artifact} =
        %Artifact{}
        |> Artifact.changeset(%{
          thread_id: thread.id,
          artifact_type: "slack_message",
          source: "slack",
          external_id: "1234567890.123456",
          url: "slack://C_CHAN_1/1234567890.123456"
        })
        |> Repo.insert()

      body = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "reaction_added",
          "reaction" => "stop_sign",
          "item" => %{
            "type" => "message",
            "channel" => "C_CHAN_1",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = slack_events_conn(conn, body)

      assert conn.status == 200

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == true

      # ADR 0016 + G9: the verified event must be recorded for audit, AND associated to the
      # resolved work thread so it appears on /threads/:id (not just held=true via Control).
      reaction_event =
        Repo.one(
          from e in Event,
            where: e.source == "slack" and e.event_type == "slack.reaction_added",
            limit: 1
        )

      assert reaction_event != nil
      assert reaction_event.thread_id == thread.id

      _ = artifact
    end

    test "valid sig + reaction_added stop_sign on non-Guild message inserts Event row, held unchanged", %{conn: conn} do
      thread = insert_thread(902)

      body = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "reaction_added",
          "reaction" => "stop_sign",
          "item" => %{
            "type" => "message",
            "channel" => "C_NO_MATCH",
            "ts" => "9999999999.000000"
          }
        }
      }

      conn = slack_events_conn(conn, body)

      assert conn.status == 200

      updated = Repo.get!(Thread, thread.id)
      assert updated.held == false

      event = Repo.one(from e in Event, where: e.event_type == "slack.reaction_added")
      assert event != nil
    end
  end

  describe "events endpoint — other events" do
    test "valid sig + unknown event type inserts Event row with slack. prefix", %{conn: conn} do
      body = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "text" => "hello"
        }
      }

      conn = slack_events_conn(conn, body)

      assert conn.status == 200

      event = Repo.one(from e in Event, where: e.event_type == "slack.message")
      assert event != nil
      assert event.source == "slack"
    end
  end

  describe "slack_channels gate" do
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

  describe "events endpoint — resolve_work_thread strategies" do
    # Test B — reaction_added via thread column lookup (no artifact)
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

    # Test C — reaction_added on a REPLY via thread_ts
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

    # Test D — message reply associates to work thread
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

    # Test E — top-level message (no thread_ts) → Event with thread_id nil
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

    # Test F — reaction_added on a reply where Slack omits `thread_ts` from item
    # (the real-world payload). Strategy (d) recovers the work thread via the
    # prior slack.message Event that recorded the reply.
    test "reaction_added stop_sign on reply with no thread_ts resolves via prior slack.message Event", %{conn: conn} do
      {:ok, thread} =
        %Thread{}
        |> Thread.changeset(%{
          anchor_type: "github_issue",
          anchor_id: "g9s4-f",
          state: "pr_open",
          slack_channel: "C123",
          slack_thread_ts: "1000.000"
        })
        |> Repo.insert()

      reply_ts = "1001.111"

      # Step 1: user replies in the thread — Slack DOES include thread_ts on message events.
      reply_body = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "channel" => "C123",
          "ts" => reply_ts,
          "thread_ts" => "1000.000",
          "text" => "did this merge cleanly?"
        }
      }

      conn1 = slack_events_conn(conn, reply_body)
      assert conn1.status == 200

      # Sanity: the message Event was associated to the work thread.
      msg_event =
        Repo.one(
          from e in Event,
            where: e.event_type == "slack.message" and e.thread_id == ^thread.id
        )

      assert msg_event != nil

      # Step 2: user reacts with :stop_sign: on their own reply. Slack does NOT
      # include `thread_ts` in `item` for reaction_added payloads — this is the
      # real-world case Jake hit on the G9 live dry-run.
      reaction_body = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "reaction_added",
          "reaction" => "stop_sign",
          "item" => %{
            "type" => "message",
            "channel" => "C123",
            "ts" => reply_ts
          }
        }
      }

      conn2 = slack_events_conn(conn, reaction_body)
      assert conn2.status == 200

      # The reaction must hold the work thread via Strategy (d).
      assert Repo.get!(Thread, thread.id).held == true

      # And the reaction Event row must be associated to the work thread.
      reaction_event =
        Repo.one(
          from e in Event,
            where: e.event_type == "slack.reaction_added"
        )

      assert reaction_event != nil
      assert reaction_event.thread_id == thread.id
    end
  end
end
