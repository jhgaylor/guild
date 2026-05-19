defmodule Guild.Worker.ContextPacket do
  @moduledoc """
  The context packet delivered to the worker before every decision call.
  Assembled by Guild.ContextAssembly.build/1.
  """

  defstruct [
    :work_item,      # map with anchor_type, anchor_id, state, owner
    :history,        # list of Event structs (up to 50)
    :artifacts,      # list of Artifact structs ([] stub for Slice 2)
    :conversations,  # [] stub for Slice 2
    :worker_notes,   # list of ContextNote structs (all human_instruction notes)
    :current_event   # the triggering Event struct or nil
  ]
end
