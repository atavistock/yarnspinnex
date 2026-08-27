defmodule Yarnspinnex.Projection do
  @moduledoc """
  A host-built view of game state that dialogue is allowed to read. `fields` holds the readable
  values; `source` keeps a reference to whatever it was projected from, for the host's own use.
  Dialogue reads `fields` and can never reach `source`.
  """

  @enforce_keys [:fields]
  defstruct fields: %{}, source: nil

  @type t :: %__MODULE__{
          fields: %{optional(atom()) => term()},
          source: term()
        }

  @doc "Builds a projection from a map of readable fields, optionally remembering its `:source`."
  @spec new(map(), keyword()) :: t()
  def new(fields, opts \\ []) when is_map(fields) do
    %__MODULE__{fields: fields, source: Keyword.get(opts, :source)}
  end
end
