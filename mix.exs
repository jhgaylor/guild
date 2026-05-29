defmodule Guild.MixProject do
  use Mix.Project

  def project do
    [
      app: :guild,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Guild.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:httpoison, "~> 2.0"},
      {:joken, "~> 2.6"},
      {:jose, "~> 1.11"},
      {:bypass, "~> 2.1", only: :test},
      {:oban, "~> 2.18"},
      # Pre-compiled rebar3 deps — rebar3 cannot run in this environment.
      # BEAM files are compiled with erlc and placed in deps/*/ebin.
      # compile: "true" runs a no-op shell command so mix calls build_symlink_structure,
      # which symlinks _build/*/lib/*/ebin -> deps/*/ebin (where our beams live).
      {:mimerl, "~> 1.4", compile: "true", override: true},
      {:certifi, "~> 2.15", compile: "true", override: true},
      {:hackney, "~> 1.21", compile: "true", override: true},
      {:idna, "~> 6.1", compile: "true", override: true},
      {:metrics, "~> 1.0", compile: "true", override: true},
      {:parse_trans, "3.4.1", compile: "true", override: true},
      {:unicode_util_compat, "~> 0.7", compile: "true", override: true},
      {:telemetry, "~> 1.0", compile: "true", override: true},
      {:cowlib, "~> 2.13", compile: "true", override: true},
      {:ranch, "~> 1.8 or ~> 2.1", compile: "true", override: true},
      {:cowboy, "~> 2.12", compile: "true", override: true},
      {:cowboy_telemetry, "~> 0.4", compile: "true", override: true},
      {:telemetry_poller, "~> 1.0", compile: "true", override: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
