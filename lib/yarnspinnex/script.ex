defmodule Yarnspinnex.Script do
  @moduledoc """
  A parsed Yarn script ready to run: nodes indexed by title, which one `Yarnspinnex.start/2`
  should enter, the `Yarnspinnex.HostFunctions` module its calls resolve against, and a
  fingerprint that cursors carry so a stale one is caught. Plain data - safe to cache (in ETS,
  a map, wherever) across dialogue turns.
  """

  alias Yarnspinnex.Analysis
  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Node

  @enforce_keys [:nodes, :start_title, :fingerprint]
  defstruct [:nodes, :start_title, :fingerprint, :functions]

  @type t :: %__MODULE__{
          nodes: %{optional(String.t()) => Node.t()},
          start_title: String.t(),
          fingerprint: non_neg_integer(),
          functions: module() | nil
        }

  @type option ::
          {:functions, module() | nil}
          | {:strict, boolean()}
          | {:known_variables, MapSet.t(String.t())}

  @fingerprint_range 4_294_967_296

  @doc false
  @spec new([Node.t()], [option()]) :: {:ok, t()} | {:error, CompileError.t()}
  def new(nodes, opts \\ [])

  def new([], _opts), do: {:error, %CompileError{description: "no nodes to compile"}}

  def new(nodes, opts) when is_list(nodes) do
    with :ok <- check_unique_titles(nodes),
         :ok <- check_jump_targets(nodes),
         :ok <- check_variables(nodes, opts) do
      {:ok,
       %__MODULE__{
         nodes: Map.new(nodes, &{&1.title, &1}),
         start_title: start_title(nodes),
         fingerprint: fingerprint(nodes),
         functions: Keyword.get(opts, :functions)
       }}
    end
  end

  defp start_title(nodes) do
    Enum.find(nodes, hd(nodes), &(&1.title == "Start")).title
  end

  # Taken over the statements without their source lines, so comment and whitespace edits keep
  # stored cursors valid while any change to a statement invalidates them.
  defp fingerprint(nodes) do
    nodes
    |> Map.new(&{&1.title, Analysis.strip_lines(&1.body)})
    |> :erlang.phash2(@fingerprint_range)
  end

  defp check_unique_titles(nodes) do
    nodes
    |> Enum.reduce_while(MapSet.new(), fn node, seen ->
      if MapSet.member?(seen, node.title) do
        {:halt, {:duplicate, node}}
      else
        {:cont, MapSet.put(seen, node.title)}
      end
    end)
    |> case do
      {:duplicate, node} ->
        {:error,
         %CompileError{
           line: node.line,
           description: "duplicate node title: #{inspect(node.title)}"
         }}

      _seen ->
        :ok
    end
  end

  defp check_jump_targets(nodes) do
    titles = MapSet.new(nodes, & &1.title)

    missing =
      for node <- nodes,
          {target, line} <- Analysis.jump_targets(node.body),
          not MapSet.member?(titles, target),
          do: {node.title, target, line}

    case missing do
      [] ->
        :ok

      [{from, target, line} | _] ->
        {:error,
         %CompileError{
           node: from,
           line: line,
           description: "jump to unknown node #{inspect(target)}"
         }}
    end
  end

  # With `strict: true`, every `$name` a script reads must be assigned somewhere in the script or
  # be among the names the host says it provides, so a misspelled variable fails here instead of
  # quietly reading as nil.
  defp check_variables(nodes, opts) do
    if Keyword.get(opts, :strict, false) do
      assigned = MapSet.new(Enum.flat_map(nodes, &Analysis.writes(&1.body)))
      known = MapSet.union(Keyword.get(opts, :known_variables, MapSet.new()), assigned)

      unknown =
        for node <- nodes,
            {name, line} <- Analysis.reads(node.body),
            not MapSet.member?(known, name),
            do: {node.title, name, line}

      case unknown do
        [] ->
          :ok

        [{title, name, line} | _] ->
          {:error,
           %CompileError{
             node: title,
             line: line,
             description:
               "$#{name} is never set or declared in the script and is not provided by " <>
                 "the host; is it misspelled?"
           }}
      end
    else
      :ok
    end
  end
end
