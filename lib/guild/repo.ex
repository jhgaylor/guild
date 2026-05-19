defmodule Guild.Repo do
  use Ecto.Repo,
    otp_app: :guild,
    adapter: Ecto.Adapters.Postgres
end
