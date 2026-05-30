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
