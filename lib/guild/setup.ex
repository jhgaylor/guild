defmodule Guild.Setup do
  import Ecto.Query

  def gaps() do
    enabled_repos =
      Guild.Repo.aggregate(
        from(r in Guild.Schema.Repo, where: r.enabled == true),
        :count,
        :full_name
      )

    workers_count = Guild.Repo.aggregate(Guild.Schema.Worker, :count, :worker_id)

    []
    |> then(fn gaps -> if enabled_repos == 0, do: [:no_repos | gaps], else: gaps end)
    |> then(fn gaps -> if workers_count == 0, do: [:no_workers | gaps], else: gaps end)
  end
end
