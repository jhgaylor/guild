defmodule GuildWeb.ThreadHTML do
  @moduledoc """
  This module contains pages rendered by ThreadController.

  See the `thread_html` directory for all templates available.
  """
  use GuildWeb, :html

  embed_templates "thread_html/*"
end
