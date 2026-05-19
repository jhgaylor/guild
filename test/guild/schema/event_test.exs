defmodule Guild.Schema.EventTest do
  use Guild.DataCase, async: true

  alias Guild.Schema.Event

  @valid_attrs %{
    source: "github",
    event_type: "issues.assigned",
    occurred_at: ~U[2026-05-19 00:00:00.000000Z],
    raw_payload: %{"id" => "evt_1"},
    idempotency_key: "github:issues.assigned:evt_1"
  }

  describe "changeset/2" do
    test "valid changeset with required fields" do
      assert %{valid?: true} = Event.changeset(%Event{}, @valid_attrs)
    end

    test "invalid without source" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :source))
      assert %{source: [_ | _]} = errors_on(changeset)
    end

    test "invalid without event_type" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :event_type))
      assert %{event_type: [_ | _]} = errors_on(changeset)
    end

    test "invalid without occurred_at" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :occurred_at))
      assert %{occurred_at: [_ | _]} = errors_on(changeset)
    end

    test "invalid without raw_payload" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :raw_payload))
      assert %{raw_payload: [_ | _]} = errors_on(changeset)
    end

    test "invalid without idempotency_key" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :idempotency_key))
      assert %{idempotency_key: [_ | _]} = errors_on(changeset)
    end
  end

  describe "unique constraint on idempotency_key" do
    test "raises on duplicate idempotency_key" do
      {:ok, _} = %Event{} |> Event.changeset(@valid_attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Event{}
               |> Event.changeset(Map.put(@valid_attrs, :idempotency_key, "github:issues.assigned:evt_1"))
               |> Repo.insert()

      assert %{idempotency_key: [_ | _]} = errors_on(changeset)
    end
  end
end
