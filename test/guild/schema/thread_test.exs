defmodule Guild.Schema.ThreadTest do
  use Guild.DataCase, async: true

  alias Guild.Schema.Thread

  @valid_attrs %{
    anchor_type: "github_issue",
    anchor_id: "I_abc123",
    state: "unnoticed"
  }

  describe "changeset/2" do
    test "valid changeset with required fields" do
      assert %{valid?: true} = Thread.changeset(%Thread{}, @valid_attrs)
    end

    test "invalid without anchor_type" do
      changeset = Thread.changeset(%Thread{}, Map.delete(@valid_attrs, :anchor_type))
      assert %{anchor_type: [_ | _]} = errors_on(changeset)
    end

    test "invalid without anchor_id" do
      changeset = Thread.changeset(%Thread{}, Map.delete(@valid_attrs, :anchor_id))
      assert %{anchor_id: [_ | _]} = errors_on(changeset)
    end

    test "invalid without state" do
      changeset = Thread.changeset(%Thread{}, Map.delete(@valid_attrs, :state))
      assert %{state: [_ | _]} = errors_on(changeset)
    end

    test "rejects illegal state values" do
      changeset = Thread.changeset(%Thread{}, Map.put(@valid_attrs, :state, "flying"))
      assert %{state: [_ | _]} = errors_on(changeset)
    end

    test "accepts all nine valid states" do
      for state <- ~w(unnoticed noticed claimed executing pr_open planned blocked done abandoned) do
        assert %{valid?: true} =
                 Thread.changeset(%Thread{}, Map.put(@valid_attrs, :state, state))
      end
    end
  end

  describe "unique constraint on (anchor_type, anchor_id)" do
    test "raises on duplicate anchor" do
      thread_attrs = %{anchor_type: "github_issue", anchor_id: "I_unique1", state: "unnoticed"}
      {:ok, _} = %Thread{} |> Thread.changeset(thread_attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Thread{} |> Thread.changeset(thread_attrs) |> Repo.insert()

      assert %{anchor_type: [_ | _]} = errors_on(changeset)
    end
  end
end
