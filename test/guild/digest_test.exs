defmodule Guild.DigestTest do
  use Guild.DataCase, async: false

  alias Guild.Repo
  alias Guild.Schema.Thread

  setup do
    bypass = Bypass.open()

    Application.put_env(:guild, :slack_bot_token, "xoxb-test-token")
    Application.put_env(:guild, :slack_channel_id, "C_DIGEST")
    Application.put_env(:guild, :slack_api_url, "http://localhost:#{bypass.port}/api/chat.postMessage")

    on_exit(fn ->
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)
      Application.delete_env(:guild, :slack_api_url)
    end)

    {:ok, bypass: bypass}
  end

  defp insert_thread(anchor_id, state, opts \\ []) do
    held = Keyword.get(opts, :held, false)

    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{anchor_type: "github_issue", anchor_id: anchor_id, state: state, held: held})
      |> Repo.insert()

    thread
  end

  defp make_stuck(thread) do
    past = DateTime.add(DateTime.utc_now(), -(49 * 3600), :second)
    Repo.update_all(
      from(t in Thread, where: t.id == ^thread.id),
      set: [updated_at: past]
    )
  end

  describe "send_digest/0" do
    test "posts Slack message with correct counts", %{bypass: bypass} do
      # done thread
      insert_thread("d1", "done")
      insert_thread("d2", "done")

      # in-flight
      insert_thread("e1", "executing")
      insert_thread("p1", "pr_open")

      # held
      insert_thread("h1", "executing", held: true)

      # stuck (executing, over 48h, not held)
      stuck = insert_thread("s1", "executing")
      make_stuck(stuck)

      received_text = Agent.start_link(fn -> nil end) |> elem(1)

      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        Agent.update(received_text, fn _ -> decoded["text"] end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      :ok = Guild.Digest.send_digest()

      text = Agent.get(received_text, & &1)
      assert text != nil

      # shipped count
      assert text =~ "2"
      # In-flight count
      assert text =~ "In-flight"
      # stuck
      assert text =~ "1"
      assert text =~ "stuck"
      # held
      assert text =~ "held"
      # worst stuck thread anchor_id
      assert text =~ "s1"
    end

    test "returns :ok (no-op) when Slack is not configured" do
      Application.delete_env(:guild, :slack_bot_token)
      Application.delete_env(:guild, :slack_channel_id)

      # Should not raise or call Bypass at all — graceful no-op
      assert :ok = Guild.Digest.send_digest()
    end

    test "digest Oban job perform/1 calls send_digest and returns :ok", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{ok: true}))
      end)

      job = %Oban.Job{args: %{}}
      assert :ok = Guild.Digest.perform(job)
    end
  end
end
