defmodule Yarnspinnex.Analysis do
  @moduledoc """
  Static walks over parsed statements, for compile-time checks and tooling. `bodies/1` is the one
  place that knows how statements nest; `flatten/1` and the walks built on it follow from that.
  """

  alias Yarnspinnex.Parser.Body
  alias Yarnspinnex.Parser.Expression

  @doc "The statement lists nested directly inside `statement`: `<<if>>` branches, else, option bodies."
  @spec bodies(Body.statement()) :: [[Body.statement()]]
  def bodies({:if, branches, else_body, _line}) do
    Enum.map(branches, fn {_condition, body} -> body end) ++ [else_body]
  end

  def bodies({:options, options, _line}) do
    Enum.map(options, fn {:option, _parts, _condition, body, _tags, _line} -> body end)
  end

  def bodies(_statement), do: []

  @doc "Every statement, depth first, including those nested in branches and options."
  @spec flatten([Body.statement()]) :: [Body.statement()]
  def flatten(statements) do
    Enum.flat_map(statements, fn statement ->
      [statement | Enum.flat_map(bodies(statement), &flatten/1)]
    end)
  end

  @doc "The expressions `statement` evaluates itself, without nested statements, with their lines."
  @spec expressions(Body.statement()) :: [{Expression.ast(), Body.line()}]
  def expressions({:line, _speaker, parts, _tags, line}), do: part_expressions(parts, line)
  def expressions({:set, _var, expr, line}), do: [{expr, line}]
  def expressions({:declare, _var, expr, line}), do: [{expr, line}]
  def expressions({:command, _name, args, line}), do: Enum.map(args, &{&1, line})

  def expressions({:if, branches, _else_body, line}) do
    Enum.map(branches, fn {condition, _body} -> {condition, line} end)
  end

  def expressions({:options, options, _line}) do
    Enum.flat_map(options, fn {:option, parts, condition, _body, _tags, line} ->
      conditions = if condition == nil, do: [], else: [{condition, line}]
      part_expressions(parts, line) ++ conditions
    end)
  end

  def expressions(_statement), do: []

  defp part_expressions(parts, line), do: for({:expr, ast} <- parts, do: {ast, line})

  @doc "Every `<<jump>>` target, with its line, including inside options and `<<if>>` branches."
  @spec jump_targets([Body.statement()]) :: [{String.t(), Body.line()}]
  def jump_targets(statements),
    do: for({:jump, target, line} <- flatten(statements), do: {target, line})

  @doc "Every `$name` read, with the line of the statement reading it."
  @spec reads([Body.statement()]) :: [{String.t(), Body.line()}]
  def reads(statements) do
    for statement <- flatten(statements),
        {ast, line} <- expressions(statement),
        {:var, name} <- Expression.subexpressions(ast),
        do: {name, line}
  end

  @doc "Every `$name` assigned by `<<set>>` or `<<declare>>`, anywhere in the statements."
  @spec writes([Body.statement()]) :: [String.t()]
  def writes(statements) do
    for {kind, var, _expr, _line} <- flatten(statements), kind in [:set, :declare], do: var
  end

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
