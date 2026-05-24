defmodule Mix.Tasks.Guild.ClaimSeed do
  use Mix.Task

  @shortdoc "Seed a single GitHub issue as a claimed Guild thread"

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string, issue_number: :integer])
    repo = opts[:repo]
    issue_number = opts[:issue_number]

    unless repo && issue_number do
      Mix.shell().error("Usage: mix guild.claim_seed --repo owner/name --issue-number N")
      exit({:shutdown, 1})
    end

    Mix.Task.run("app.start")

    case Guild.Claiming.claim_issue(repo, issue_number) do
      {:ok, %{thread: thread, fountain_conv_id: conv_id}} ->
        Mix.shell().info("thread_id: #{thread.id}")
        Mix.shell().info("fountain_conv_id: #{conv_id}")

      {:error, reason} ->
        Mix.shell().error("Failed to claim issue: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
