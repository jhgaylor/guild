System.put_env("SECRET_KEY_BASE", "fB6zE3OtkXO25/CXoYMbdrVaeK6UnpnmX94kfOzhHMlV04n1VtPTpi52g7Kq4F3e")
System.put_env("OPERATOR_USERNAME", "test_operator")
System.put_env("OPERATOR_PASSWORD", "test_password")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Guild.Repo, :manual)
ExUnit.configure(exclude: [:e2e, :integration])
