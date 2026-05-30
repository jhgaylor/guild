defmodule GuildWeb.Format do
  @moduledoc """
  Small presentational helpers for the operator UI.
  """

  @doc """
  Render a DateTime as `YYYY-MM-DD HH:MM` — drops sub-second precision
  and the timezone suffix so tables stay readable.
  """
  def time(nil), do: ""

  def time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  def time(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  def time(other), do: to_string(other)

  @doc """
  Human-readable elapsed time: "just now", "5m ago", "3h ago", "2d ago".
  """
  def time_ago(nil), do: "unknown"

  def time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  def time_ago(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> time_ago()
  end

  def time_ago(other), do: to_string(other)

  @doc """
  First 8 chars of a UUID for compact table display.
  """
  def short_id(nil), do: ""
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(other), do: other |> to_string() |> short_id()

  @doc """
  GitHub URL for a `github_issue` anchor — `owner/repo#N` style anchors
  aren't stored, but we can reconstruct the URL when the anchor_id is a
  plain integer and we know the owner/repo from somewhere else. For now
  this just renders the anchor_id verbatim; callers can pass an explicit
  href if they have one.
  """
  def anchor_label(%{anchor_type: "github_issue", anchor_id: id}), do: "issue ##{id}"
  def anchor_label(%{anchor_type: type, anchor_id: id}), do: "#{type} #{id}"
end
