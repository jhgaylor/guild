defmodule Guild.StartupRecovery do
  @moduledoc """
  On startup, scans for threads in non-terminal states owned by this worker identity.
  Logs each found thread. Does not re-dispatch or change any state.
  """

  require Logger
  import Ecto.Query

  alias Guild.Repo
  alias Guild.Schema.Thread
  alias Guild.StateMachine

  @doc """
  Query all non-terminal threads owned by the configured worker identity and log each one.
  Returns {:ok, count} where count is the number of threads found.
  """
  def recover do
    worker_identity = Application.get_env(:guild, :worker_identity)
    active = StateMachine.active_states() |> Enum.map(&Atom.to_string/1)

    threads =
      Repo.all(
        from t in Thread,
          where: t.state in ^active and t.owner == ^worker_identity
      )

    for thread <- threads do
      Logger.info("StartupRecovery: found non-terminal thread #{thread.id} in state #{thread.state}")
    end

    {:ok, length(threads)}
  end
end
