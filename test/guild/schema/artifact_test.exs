defmodule Guild.Schema.ArtifactTest do
  use Guild.DataCase, async: true

  alias Guild.Schema.{Artifact, Thread}

  defp insert_thread! do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{
        anchor_type: "github_issue",
        anchor_id: "I_art_#{System.unique_integer([:positive])}",
        state: "unnoticed"
      })
      |> Repo.insert()

    thread
  end

  describe "changeset/2" do
    test "valid changeset with required fields" do
      thread = insert_thread!()

      attrs = %{
        thread_id: thread.id,
        artifact_type: "pull_request",
        source: "github",
        external_id: "pr_100"
      }

      assert %{valid?: true} = Artifact.changeset(%Artifact{}, attrs)
    end

    test "invalid without thread_id" do
      attrs = %{artifact_type: "pull_request", source: "github", external_id: "pr_101"}
      changeset = Artifact.changeset(%Artifact{}, attrs)
      assert %{thread_id: [_ | _]} = errors_on(changeset)
    end

    test "invalid without artifact_type" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, source: "github", external_id: "pr_102"}
      changeset = Artifact.changeset(%Artifact{}, attrs)
      assert %{artifact_type: [_ | _]} = errors_on(changeset)
    end

    test "invalid without source" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, artifact_type: "pull_request", external_id: "pr_103"}
      changeset = Artifact.changeset(%Artifact{}, attrs)
      assert %{source: [_ | _]} = errors_on(changeset)
    end

    test "invalid without external_id" do
      thread = insert_thread!()
      attrs = %{thread_id: thread.id, artifact_type: "pull_request", source: "github"}
      changeset = Artifact.changeset(%Artifact{}, attrs)
      assert %{external_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "unique constraint on (source, external_id)" do
    test "raises on duplicate source+external_id" do
      thread = insert_thread!()

      attrs = %{
        thread_id: thread.id,
        artifact_type: "pull_request",
        source: "github",
        external_id: "pr_unique_1"
      }

      {:ok, _} = %Artifact{} |> Artifact.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Artifact{} |> Artifact.changeset(attrs) |> Repo.insert()

      assert %{source: [_ | _]} = errors_on(changeset)
    end
  end
end
