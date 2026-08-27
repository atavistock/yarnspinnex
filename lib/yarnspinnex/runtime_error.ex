defmodule Yarnspinnex.RuntimeError do
  @moduledoc """
  Raised by `Yarnspinnex.step/3` and `Yarnspinnex.choose/4` when a statement cannot run: a type
  error in an expression, a host function that failed, a cursor that does not fit the script, or
  a script that loops without ever producing an event. `node` and `line` locate the statement;
  `path` and `index` are the cursor position for cases with no statement to point at.
  """

  defexception [:description, :node, :line, :path, :index]

  @type t :: %__MODULE__{
          description: String.t(),
          node: String.t() | nil,
          line: pos_integer() | nil,
          path: [{non_neg_integer(), Yarnspinnex.Cursor.selector()}],
          index: non_neg_integer() | nil
        }

  @impl true
  def message(%__MODULE__{description: description, node: nil}), do: description

  def message(%__MODULE__{description: description, node: node, line: line})
      when is_integer(line) do
    "line #{line} in node #{inspect(node)}: #{description}"
  end

  def message(%__MODULE__{description: description, node: node, path: path, index: index}) do
    "node #{inspect(node)}, #{position(index, path)}: #{description}"
  end

  # The path is innermost first, so folding it reads from the statement outward.
  defp position(index, path) when is_list(path) do
    Enum.reduce(path, "statement #{index}", fn
      {parent, {:option, offset}}, acc -> "#{acc} inside option #{offset} of statement #{parent}"
      {parent, {:if, :else}}, acc -> "#{acc} inside the else branch of statement #{parent}"
      {parent, {:if, branch}}, acc -> "#{acc} inside branch #{branch} of statement #{parent}"
      _other, acc -> acc
    end)
  end

  defp position(index, _path), do: "statement #{inspect(index)}"
end
