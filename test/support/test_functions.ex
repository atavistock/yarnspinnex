defmodule Yarnspinnex.TestFunctions do
  @moduledoc """
  Host functions for tests. `call/3` reads the context exactly as the host passed it to
  `Yarnspinnex.step/3`, structs and atom keys included.
  """

  @behaviour Yarnspinnex.HostFunctions

  @impl true
  def declared, do: [{"party_has_class", 1}, {"gold", 0}]

  @impl true
  def call("party_has_class", [class], context), do: class in context.party
  def call("gold", [], context), do: context.player.gold
end
