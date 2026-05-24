ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Guild.Repo, :manual)
ExUnit.configure(exclude: [:e2e, :integration])
