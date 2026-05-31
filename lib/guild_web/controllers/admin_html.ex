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
  def verdict_badge_class("failed"), do: "badge--red"
  def verdict_badge_class(_), do: "badge--gray"

  def action_badge_class("issue_created"), do: "badge--green"
  def action_badge_class("reference_reply_posted"), do: "badge--blue"
  def action_badge_class("dry_run"), do: "badge--yellow"
  def action_badge_class("noise"), do: "badge--gray"
  def action_badge_class("failed"), do: "badge--red"
  def action_badge_class(_), do: "badge--gray"
end
