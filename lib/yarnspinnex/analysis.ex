defmodule Yarnspinnex.Analysis do
  @moduledoc """
  Static walks over parsed statements, for compile-time checks and tooling: jump targets and
  variable reads, each paired with the source line they appear on, variable writes, and a
  line-free view of the statements that a script's fingerprint is taken over.
  """

  alias Yarnspinnex.Parser.Body

  @doc "Every `<<jump>>` target, with its line, including inside options and `<<if>>` branches."
  @spec jump_targets([Body.statement()]) :: [{String.t(), Body.line()}]
  def jump_targets(statements), do: Enum.flat_map(statements, &statement_jumps/1)

  defp statement_jumps({:jump, target, line}), do: [{target, line}]

  defp statement_jumps({:if, branches, else_body, _line}) do
    Enum.flat_map(branches, fn {_condition, body} -> jump_targets(body) end) ++
      jump_targets(else_body)
  end

  defp statement_jumps({:options, options, _line}) do
    Enum.flat_map(options, fn {:option, _parts, _condition, body, _tags, _line} ->
      jump_targets(body)
    end)
  end

  defp statement_jumps(_other), do: []

  @doc "Every `$name` read, with the line of the statement reading it."
  @spec reads([Body.statement()]) :: [{String.t(), Body.line()}]
  def reads(statements), do: Enum.flat_map(statements, &statement_reads/1)

  defp statement_reads({:line, _speaker, parts, _tags, line}), do: parts_reads(parts, line)
  defp statement_reads({:set, _var, expr, line}), do: expr_reads(expr, line)
  defp statement_reads({:declare, _var, expr, line}), do: expr_reads(expr, line)

  defp statement_reads({:command, _name, args, line}) do
    Enum.flat_map(args, &expr_reads(&1, line))
  end

  defp statement_reads({:if, branches, else_body, line}) do
    Enum.flat_map(branches, fn {condition, body} -> expr_reads(condition, line) ++ reads(body) end) ++
      reads(else_body)
  end

  defp statement_reads({:options, options, _line}) do
    Enum.flat_map(options, fn {:option, parts, condition, body, _tags, line} ->
      parts_reads(parts, line) ++ expr_reads(condition, line) ++ reads(body)
    end)
  end

  defp statement_reads(_other), do: []

  defp parts_reads(parts, line) do
    Enum.flat_map(parts, fn
      {:expr, ast} -> expr_reads(ast, line)
      {:text, _text} -> []
    end)
  end

  defp expr_reads(nil, _line), do: []
  defp expr_reads({:var, name}, line), do: [{name, line}]
  defp expr_reads({:field, base, _field}, line), do: expr_reads(base, line)
  defp expr_reads({:call, _name, args}, line), do: Enum.flat_map(args, &expr_reads(&1, line))
  defp expr_reads({:not, expr}, line), do: expr_reads(expr, line)
  defp expr_reads({:neg, expr}, line), do: expr_reads(expr, line)

  defp expr_reads({:binop, _op, left, right}, line) do
    expr_reads(left, line) ++ expr_reads(right, line)
  end

  defp expr_reads(_literal, _line), do: []

  @doc "Every `$name` assigned by `<<set>>` or `<<declare>>`, anywhere in the statements."
  @spec writes([Body.statement()]) :: [String.t()]
  def writes(statements), do: Enum.flat_map(statements, &statement_writes/1)

  defp statement_writes({:set, var, _expr, _line}), do: [var]
  defp statement_writes({:declare, var, _expr, _line}), do: [var]

  defp statement_writes({:if, branches, else_body, _line}) do
    Enum.flat_map(branches, fn {_condition, body} -> writes(body) end) ++ writes(else_body)
  end

  defp statement_writes({:options, options, _line}) do
    Enum.flat_map(options, fn {:option, _parts, _condition, body, _tags, _line} ->
      writes(body)
    end)
  end

  defp statement_writes(_other), do: []

  @doc """
  The statements with their source lines removed. A script's fingerprint is taken over this, so
  editing comments or blank lines does not invalidate stored cursors while changing a statement does.
  """
  @spec strip_lines([Body.statement()]) :: [tuple() | :stop]
  def strip_lines(statements), do: Enum.map(statements, &strip_statement/1)

  defp strip_statement({:line, speaker, parts, tags, _line}), do: {:line, speaker, parts, tags}

  defp strip_statement({:options, options, _line}),
    do: {:options, Enum.map(options, &strip_option/1)}

  defp strip_statement({:set, var, expr, _line}), do: {:set, var, expr}
  defp strip_statement({:declare, var, expr, _line}), do: {:declare, var, expr}
  defp strip_statement({:jump, target, _line}), do: {:jump, target}
  defp strip_statement({:stop, _line}), do: :stop
  defp strip_statement({:command, name, args, _line}), do: {:command, name, args}

  defp strip_statement({:if, branches, else_body, _line}) do
    stripped = Enum.map(branches, fn {condition, body} -> {condition, strip_lines(body)} end)
    {:if, stripped, strip_lines(else_body)}
  end

  defp strip_option({:option, parts, condition, body, tags, _line}) do
    {:option, parts, condition, strip_lines(body), tags}
  end
end
