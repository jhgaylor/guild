defmodule GuildWeb.AdminHTML do
  @moduledoc """
  This module contains pages rendered by AdminController.

  See the `admin_html` directory for all templates available.
  """
  use GuildWeb, :html

  embed_templates "admin_html/*"

  def status_label(:ready), do: "ready"
  def status_label(:unconfigured), do: "unconfigured"
  def status_label(:failing), do: "failing"
  def status_label(_), do: "unknown"

  def slack_status_label(:ready, _details), do: "ready"
  def slack_status_label(:partial, _details), do: "inbound ready, outbound unconfigured"
  def slack_status_label(:unconfigured, _details), do: "unconfigured"
  def slack_status_label(_, _), do: "unknown"

  def verdict_badge_class("new_work"), do: "badge--blue"
  def verdict_badge_class("refers_to_existing"), do: "badge--purple"
  def verdict_badge_class("noise"), do: "badge--gray"
  def verdict_badge_class("skipped_rate_limit"), do: "badge--yellow"
  def verdict_badge_class("failed"), do: "badge--red"
  def verdict_badge_class(_), do: "badge--gray"

  def action_badge_class("issue_created"), do: "badge--green"
  def action_badge_class("reference_reply_posted"), do: "badge--blue"
  def action_badge_class("dry_run"), do: "badge--yellow"
  def action_badge_class("noise"), do: "badge--gray"
  def action_badge_class("skipped"), do: "badge--gray"
  def action_badge_class("failed"), do: "badge--red"
  def action_badge_class(_), do: "badge--gray"

  # Format a USD cost into a human-readable string. Sub-cent values render as
  # tenths of a cent so per-classification cost stays visible at typical
  # gpt-4o-mini / gemini-flash price points (~$0.0001–$0.001 each).
  def format_cost(nil), do: "—"
  def format_cost(c) when is_number(c) and c == 0, do: "$0"
  def format_cost(c) when is_number(c) and c >= 0.01, do: "$#{:erlang.float_to_binary(c * 1.0, decimals: 4)}"
  def format_cost(c) when is_number(c) and c >= 0.0001, do: "$#{:erlang.float_to_binary(c * 1.0, decimals: 6)}"
  def format_cost(c) when is_number(c) and c > 0, do: "<$0.000001"
  def format_cost(_), do: "—"

  # Strip the provider prefix from a model id for compact display in the
  # inbox table. "openai/gpt-4o-mini" → "gpt-4o-mini".
  def short_model(nil), do: "—"
  def short_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [_provider, name] -> name
      [single] -> single
    end
  end
end
