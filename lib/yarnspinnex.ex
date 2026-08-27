defmodule Yarnspinnex do
  @moduledoc """
  Parses Yarn Spinner dialogue into a `Yarnspinnex.Script` (plain data, safe to cache) and runs
  it one event at a time: `step/3` returns the next line, command, or option group along with an
  updated `Yarnspinnex.Cursor`, and `choose/4` answers an option group. Nothing blocks.

  A script reads two collections of values. `vars` live in the cursor, are written by `<<set>>`,
  and persist with it. `context` is live host state passed to each `step/3` call and never
  persisted - it is where structs, repos, and anything a game system owns belong. A name found in
  both resolves to context; declare the context names at compile time to make that a hard error
  instead of a surprise. In both, `$player` in a script and `player:` in Elixir are one name.
  """

  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Cursor
  alias Yarnspinnex.Functions
  alias Yarnspinnex.Interpreter
  alias Yarnspinnex.Parser
  alias Yarnspinnex.Script
  alias Yarnspinnex.Vars

  @type compile_option ::
          {:functions, module()}
          | {:context, [atom() | String.t()]}
          | {:variables, [atom() | String.t()]}
          | {:strict, boolean()}

  @doc """
  Parses and validates Yarn source into a `Yarnspinnex.Script`.

  Options:

    * `:functions` - a `Yarnspinnex.HostFunctions` module; every call in the script is checked
      against its `declared/0`, by name and arity.
    * `:context` - the names the host supplies as context at run time. Assigning to one is
      rejected here rather than silently losing to context later.
    * `:variables` - names the host provides as `vars` (set by other scripts, or persisted), for
      `:strict`.
    * `:strict` - when true, every `$name` the script reads must be assigned somewhere in it or
      be listed under `:context` or `:variables`, so a misspelled name is a compile error instead
      of a `nil`.
  """
  @spec compile_string(String.t(), [compile_option()]) ::
          {:ok, Script.t()} | {:error, CompileError.t()}
  def compile_string(source, opts \\ []) when is_binary(source) and is_list(opts) do
    opts = Keyword.validate!(opts, functions: nil, context: [], variables: [], strict: false)
    functions = check_functions_module!(opts[:functions])
    context = MapSet.new(opts[:context], &to_string/1)
    provided = MapSet.new(opts[:variables], &to_string/1)

    with {:ok, calls} <- declared_calls(functions),
         {:ok, nodes} <- Parser.parse(source, %{calls: calls, context: context}) do
      Script.new(nodes,
        functions: functions,
        strict: opts[:strict],
        known_variables: MapSet.union(context, provided)
      )
    end
  end

  defp check_functions_module!(nil), do: nil

  defp check_functions_module!(module) when is_atom(module) do
    implemented? =
      Code.ensure_loaded?(module) and function_exported?(module, :declared, 0) and
        function_exported?(module, :call, 3)

    if implemented? do
      module
    else
      raise ArgumentError,
            "functions: #{inspect(module)} does not implement Yarnspinnex.HostFunctions " <>
              "(declared/0 and call/3)"
    end
  end

  defp check_functions_module!(other) do
    raise ArgumentError, "functions: expected a module, got #{inspect(other)}"
  end

  defp declared_calls(nil), do: {:ok, Functions.builtins()}

  defp declared_calls(module) do
    Enum.reduce_while(module.declared(), {:ok, Functions.builtins()}, fn
      {name, arity}, {:ok, calls} when is_binary(name) and is_integer(arity) and arity >= 0 ->
        if Functions.builtin?(name) do
          {:halt,
           {:error,
            %CompileError{description: "#{name} is a built-in function and cannot be redeclared"}}}
        else
          {:cont, {:ok, Map.put(calls, name, arity)}}
        end

      other, _acc ->
        {:halt,
         {:error,
          %CompileError{
            description:
              "#{inspect(module)}.declared/0 must return {name, arity} pairs, got #{inspect(other)}"
          }}}
    end)
  end

  @doc "A cursor at the start node (`\"Start\"` if present, else the first node) holding `vars`."
  @spec start(Script.t(), Vars.vars()) :: Cursor.t()
  def start(%Script{} = script, vars \\ %{}) do
    %Cursor{node: script.start_title, script: script.fingerprint, vars: Vars.normalize(vars)}
  end

  @doc "A cursor at the node titled `title` holding `vars`."
  @spec enter(Script.t(), String.t(), Vars.vars()) ::
          {:ok, Cursor.t()} | {:error, :unknown_node}
  def enter(%Script{} = script, title, vars \\ %{}) do
    if Map.has_key?(script.nodes, title) do
      {:ok, %Cursor{node: title, script: script.fingerprint, vars: Vars.normalize(vars)}}
    else
      {:error, :unknown_node}
    end
  end

  @doc """
  Advances to the next event: a line, a command, an option group, or the end of the dialogue.

  `context` is host state the script can read but not write; it is handed to
  `Yarnspinnex.HostFunctions.call/3` untouched. Raises `Yarnspinnex.RuntimeError`, located at
  the offending statement, when a statement cannot run or the cursor does not fit the script.
  """
  @spec step(Script.t(), Cursor.t(), Vars.collection()) :: Interpreter.event()
  defdelegate step(script, cursor, context \\ %{}), to: Interpreter

  @doc "Answers the option group `step/3` returned by picking the option at `index`."
  @spec choose(Script.t(), Cursor.t(), non_neg_integer(), Vars.collection()) ::
          {:ok, Cursor.t()} | {:error, Interpreter.choose_error()}
  defdelegate choose(script, cursor, index, context \\ %{}), to: Interpreter

  @doc """
  Whether `cursor` can be resumed against `script`: it was made from this exact version of the
  script and points at a real position in it. Call this on a cursor loaded from storage to decide
  between resuming and restarting; `step/3` performs the same check and raises instead.
  """
  @spec check_cursor(Script.t(), Cursor.t()) :: :ok | {:error, Interpreter.cursor_error()}
  defdelegate check_cursor(script, cursor), to: Interpreter

  @doc "Titles of every node in `script`."
  @spec node_titles(Script.t()) :: [String.t()]
  def node_titles(%Script{} = script), do: Map.keys(script.nodes)
end
