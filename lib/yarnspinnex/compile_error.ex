defmodule Yarnspinnex.CompileError do
  @moduledoc """
  Why a script could not be compiled: a parse failure, or a validation failure such as a jump to
  a missing node. `line` (1-based, in the source string) and `node` locate the problem when known.
  """

  defexception [:description, :node, :line]

  @type t :: %__MODULE__{
          description: String.t(),
          node: String.t() | nil,
          line: pos_integer() | nil
        }

  @impl true
  def message(%__MODULE__{description: description, node: nil, line: nil}), do: description

  def message(%__MODULE__{description: description, node: node, line: nil}) do
    "node #{inspect(node)}: #{description}"
  end

  def message(%__MODULE__{description: description, node: nil, line: line}) do
    "line #{line}: #{description}"
  end

  def message(%__MODULE__{description: description, node: node, line: line}) do
    "line #{line} in node #{inspect(node)}: #{description}"
  end
end
