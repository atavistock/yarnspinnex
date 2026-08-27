defmodule Yarnspinnex.Interpreter do
  @moduledoc """
  Advances a `Yarnspinnex.Cursor` through a `Yarnspinnex.Script` one event at a time. Statements
  with nothing to show the host (`<<set>>`, `<<declare>>`, `<<if>>`, `<<jump>>`) are absorbed
  inside `step/3`, so every result is a line, a command, an option group, or the end.
  """

  alias Yarnspinnex.Cursor
  alias Yarnspinnex.Functions
  alias Yarnspinnex.Line
  alias Yarnspinnex.Ops
  alias Yarnspinnex.Option
  alias Yarnspinnex.Script
  alias Yarnspinnex.Vars

  @type event ::
          {:line, Line.t(), Cursor.t()}
          | {:command, String.t(), [term()], Cursor.t()}
          | {:options, [Option.t()], Cursor.t()}
          | {:done, Cursor.t()}

  @type choose_error :: :no_options | :invalid_option | :option_disabled
  @type cursor_error :: :stale_script | :unknown_node | :invalid_position

  # How many statements one step may pass through without producing an event before it is
  # declared stuck; a script that jumps in a circle without saying anything hits this.
  @max_transitions 1_000_000

  @spec step(Script.t(), Cursor.t(), Vars.collection()) :: event()
  def step(%Script{} = script, %Cursor{} = cursor, context \\ %{}) do
    do_step(script, cursor, env!(script, cursor, context), @max_transitions)
  end

  @spec choose(Script.t(), Cursor.t(), non_neg_integer(), Vars.collection()) ::
          {:ok, Cursor.t()} | {:error, choose_error()}
  def choose(%Script{} = script, %Cursor{} = cursor, index, context \\ %{})
      when is_integer(index) and index >= 0 do
    env = env!(script, cursor, context)

    case remaining!(script, cursor) do
      [{:options, group, _line} | _] -> choose_from(group, index, cursor, scope(env, cursor))
      _other -> {:error, :no_options}
    end
  end

  @spec check_cursor(Script.t(), Cursor.t()) :: :ok | {:error, cursor_error()}
  def check_cursor(%Script{} = script, %Cursor{} = cursor) do
    with :ok <- check_identity(script, cursor),
         {:ok, _statements} <- remaining(script, cursor) do
      :ok
    else
      :error -> {:error, :invalid_position}
      {:error, reason} -> {:error, reason}
    end
  end

  # Fingerprint, node, and well-formedness: the checks cheap enough to run on every step.
  defp check_identity(script, cursor) do
    cond do
      cursor.script != script.fingerprint -> {:error, :stale_script}
      not Map.has_key?(script.nodes, cursor.node) -> {:error, :unknown_node}
      not well_formed?(cursor) -> {:error, :invalid_position}
      true -> :ok
    end
  end

  defp well_formed?(%Cursor{index: index, path: path}) do
    is_integer(index) and index >= 0 and is_list(path) and Enum.all?(path, &well_formed_entry?/1)
  end

  defp well_formed_entry?({index, {:if, branch}}) when is_integer(index) and index >= 0 do
    branch == :else or (is_integer(branch) and branch >= 0)
  end

  defp well_formed_entry?({index, {:option, offset}}) when is_integer(index) and index >= 0 do
    is_integer(offset) and offset >= 0
  end

  defp well_formed_entry?(_other), do: false

  # What every step shares: the host's context and functions, checked once.
  defp env!(script, cursor, context) do
    case check_identity(script, cursor) do
      :ok -> :ok
      {:error, reason} -> raise located(cursor, nil, cursor_problem(reason))
    end

    Vars.check_context!(context)
    %{context: context, functions: script.functions}
  end

  defp cursor_problem(:stale_script),
    do: "cursor was created for a different version of the script"

  defp cursor_problem(:unknown_node), do: "cursor points at a node that is not in the script"
  defp cursor_problem(:invalid_position), do: "cursor position is not well formed"

  # What an expression sees: the cursor's variables on top of the shared environment.
  defp scope(env, cursor), do: Map.put(env, :vars, cursor.vars)

  defp do_step(_script, cursor, _env, 0) do
    raise located(
            cursor,
            nil,
            "no line, command, or option group after #{@max_transitions} statements; " <>
              "is there a jump loop?"
          )
  end

  defp do_step(script, cursor, env, budget) do
    case remaining!(script, cursor) do
      [] ->
        leave_list(script, cursor, env, budget)

      [{:options, group, _line} | _] ->
        {:options, offer(group, cursor, scope(env, cursor)), cursor}

      [statement | _] ->
        exec(statement, script, cursor, env, budget)
    end
  end

  defp choose_from(group, index, cursor, scope) do
    case Enum.at(group, index) do
      nil ->
        {:error, :invalid_option}

      {:option, _parts, condition, _body, _tags, line} ->
        if guard(cursor, line, fn -> enabled?(condition, scope) end) do
          {:ok, descend(cursor, {:option, index})}
        else
          {:error, :option_disabled}
        end
    end
  end

  # -- position ---------------------------------------------------------------

  defp remaining!(script, cursor) do
    case remaining(script, cursor) do
      {:ok, statements} -> statements
      :error -> raise located(cursor, nil, "cursor position does not match the script")
    end
  end

  # Statements of the innermost list from the cursor's index onward; an index past the end of
  # the list (one past is the finished state) does not fit the script.
  defp remaining(script, cursor) do
    with {:ok, statements} <- locate(script, cursor) do
      drop_exactly(statements, cursor.index)
    end
  end

  defp drop_exactly(statements, 0), do: {:ok, statements}
  defp drop_exactly([_statement | rest], count), do: drop_exactly(rest, count - 1)
  defp drop_exactly([], _count), do: :error

  defp locate(script, cursor) do
    script |> node_body(cursor.node) |> resolve(Enum.reverse(cursor.path))
  end

  defp node_body(script, title), do: Map.fetch!(script.nodes, title).body

  defp resolve(statements, []), do: {:ok, statements}

  defp resolve(statements, [{index, {:if, :else}} | inner]) do
    case Enum.at(statements, index) do
      {:if, _branches, else_body, _line} -> resolve(else_body, inner)
      _other -> :error
    end
  end

  defp resolve(statements, [{index, {:if, branch}} | inner]) do
    with {:if, branches, _else_body, _line} <- Enum.at(statements, index),
         {_condition, body} <- Enum.at(branches, branch) do
      resolve(body, inner)
    else
      _other -> :error
    end
  end

  defp resolve(statements, [{index, {:option, offset}} | inner]) do
    with {:options, group, _line} <- Enum.at(statements, index),
         {:option, _parts, _condition, body, _tags, _option_line} <- Enum.at(group, offset) do
      resolve(body, inner)
    else
      _other -> :error
    end
  end

  # The innermost list is exhausted: continue after the construct that opened it.
  defp leave_list(_script, %Cursor{path: []} = cursor, _env, _budget), do: {:done, cursor}

  defp leave_list(script, %Cursor{path: [{index, _selector} | outer]} = cursor, env, budget) do
    do_step(script, %{cursor | path: outer, index: index + 1}, env, budget - 1)
  end

  defp advance(cursor), do: %{cursor | index: cursor.index + 1}

  defp descend(cursor, selector) do
    %{cursor | path: [{cursor.index, selector} | cursor.path], index: 0}
  end

  # -- statements -------------------------------------------------------------

  # Every evaluation runs under `guard/3` so an error names the statement's line; the
  # interpreter's own recursion stays outside it so `<<jump>>` remains a tail call.

  defp exec({:line, speaker, parts, tags, line}, _script, cursor, env, _budget) do
    text = guard(cursor, line, fn -> interpolate(parts, scope(env, cursor)) end)
    {:line, %Line{speaker: speaker, text: text, tags: tags, id: tag_id(tags)}, advance(cursor)}
  end

  defp exec({:command, name, arg_exprs, line}, _script, cursor, env, _budget) do
    scope = scope(env, cursor)
    args = guard(cursor, line, fn -> Enum.map(arg_exprs, &eval_expr(&1, scope)) end)
    {:command, name, args, advance(cursor)}
  end

  defp exec({:set, var, expr, line}, script, cursor, env, budget) do
    value = guard(cursor, line, fn -> eval_expr(expr, scope(env, cursor)) end)
    do_step(script, advance(put_var(cursor, var, value)), env, budget - 1)
  end

  defp exec({:declare, var, expr, line}, script, cursor, env, budget) do
    cursor =
      if Map.has_key?(cursor.vars, var) do
        cursor
      else
        put_var(cursor, var, guard(cursor, line, fn -> eval_expr(expr, scope(env, cursor)) end))
      end

    do_step(script, advance(cursor), env, budget - 1)
  end

  defp exec({:stop, _line}, script, cursor, _env, _budget) do
    {:done, %{cursor | path: [], index: length(node_body(script, cursor.node))}}
  end

  defp exec({:jump, target, _line}, script, cursor, env, budget) do
    do_step(script, %{cursor | node: target, path: [], index: 0}, env, budget - 1)
  end

  defp exec({:if, branches, _else_body, line}, script, cursor, env, budget) do
    scope = scope(env, cursor)

    branch =
      guard(cursor, line, fn ->
        Enum.find_index(branches, fn {condition, _body} ->
          Ops.boolean!(eval_expr(condition, scope))
        end) || :else
      end)

    do_step(script, descend(cursor, {:if, branch}), env, budget - 1)
  end

  defp put_var(cursor, name, value), do: %{cursor | vars: Map.put(cursor.vars, name, value)}

  defp offer(group, cursor, scope) do
    Enum.with_index(group, fn {:option, parts, condition, _body, tags, line}, index ->
      guard(cursor, line, fn ->
        %Option{
          index: index,
          text: interpolate(parts, scope),
          enabled?: enabled?(condition, scope),
          tags: tags,
          id: tag_id(tags)
        }
      end)
    end)
  end

  defp enabled?(nil, _scope), do: true
  defp enabled?(condition, scope), do: Ops.boolean!(eval_expr(condition, scope))

  defp tag_id(tags) do
    Enum.find_value(tags, fn
      "line:" <> id -> id
      _other -> nil
    end)
  end

  defp interpolate(parts, scope) do
    Enum.map_join(parts, fn
      {:text, str} -> str
      {:expr, ast} -> Ops.to_text(eval_expr(ast, scope))
    end)
  end

  defp guard(cursor, line, fun) do
    fun.()
  rescue
    error in [ArgumentError, FunctionClauseError, UndefinedFunctionError] ->
      reraise located(cursor, line, Exception.message(error)), __STACKTRACE__
  end

  defp located(cursor, line, description) do
    %Yarnspinnex.RuntimeError{
      description: description,
      node: cursor.node,
      line: line,
      path: cursor.path,
      index: cursor.index
    }
  end

  # -- expression evaluation ------------------------------------------------

  defp eval_expr(number, _scope) when is_number(number), do: number
  defp eval_expr(string, _scope) when is_binary(string), do: string
  defp eval_expr(boolean, _scope) when is_boolean(boolean), do: boolean

  # Host context wins over dialogue's own memory; the compiler rejects scripts that assign to it.
  defp eval_expr({:var, name}, scope) do
    case Vars.fetch(scope.context, name) do
      {:ok, value} -> value
      :error -> Map.get(scope.vars, name)
    end
  end

  defp eval_expr({:field, base, field}, scope), do: Ops.get_field(eval_expr(base, scope), field)

  defp eval_expr({:call, name, arg_exprs}, scope) do
    args = Enum.map(arg_exprs, &eval_expr(&1, scope))

    cond do
      Functions.builtin?(name) -> Functions.call(name, args)
      scope.functions -> scope.functions.call(name, args, scope.context)
      true -> raise ArgumentError, "unknown or unsupported yarn function: #{name}"
    end
  end

  defp eval_expr({:not, expr}, scope), do: not Ops.boolean!(eval_expr(expr, scope))
  defp eval_expr({:neg, expr}, scope), do: -eval_expr(expr, scope)

  # `and` and `or` short-circuit, so the right side is evaluated only when it can matter.
  defp eval_expr({:binop, :and, left, right}, scope) do
    Ops.boolean!(eval_expr(left, scope)) and Ops.boolean!(eval_expr(right, scope))
  end

  defp eval_expr({:binop, :or, left, right}, scope) do
    Ops.boolean!(eval_expr(left, scope)) or Ops.boolean!(eval_expr(right, scope))
  end

  defp eval_expr({:binop, :xor, left, right}, scope) do
    Ops.boolean!(eval_expr(left, scope)) != Ops.boolean!(eval_expr(right, scope))
  end

  defp eval_expr({:binop, op, left, right}, scope) do
    Ops.binop(op, eval_expr(left, scope), eval_expr(right, scope))
  end
end
