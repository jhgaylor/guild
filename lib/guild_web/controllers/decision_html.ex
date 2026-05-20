defmodule GuildWeb.DecisionHTML do
  @moduledoc """
  This module contains pages rendered by DecisionController.

  See the `decision_html` directory for all templates available.
  """
  use GuildWeb, :html

  embed_templates "decision_html/*"
end
