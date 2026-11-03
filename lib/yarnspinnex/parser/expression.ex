defmodule Yarnspinnex.Parser.Expression do
  @moduledoc """
  Parses a Yarn expression (as found inside `{...}` interpolation, `<<if
  ...>>`, `<<set ... = ...>>`, and command arguments) into a small, plain
  data AST that `Yarnspinnex.Interpreter` evaluates against the cursor's
  variables. Tokenizing is delegated to `Yarnspinnex.Parser.Lexer`; this
  module only builds the AST from the resulting tokens.
  """

  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Ops
  alias Yarnspinnex.Parser.Lexer

  @typedoc "A bare number, string, or boolean evaluates to itself; everything else is a tagged tuple."
  @type ast ::
          number()
          | String.t()
          | boolean()
          | {:var, String.t()}
          | {:field, ast(), String.t()}
          | {:call, String.t(), [ast()]}
          | {:not, ast()}
          | {:neg, ast()}
          | {:binop, Ops.operator(), ast(), ast()}

  # Binary operators from lowest precedence to highest; every level is left-associative.
  @levels [[:xor], [:or], [:and], [:==, :!=], [:<, :>, :<=, :>=], [:+, :-], [:*, :/, :%]]
  @precedence for {ops, level} <- Enum.with_index(@levels), op <- ops, into: %{}, do: {op, level}
  @unary_level length(@levels)

  @doc "Parses expression source into an AST, raising on invalid syntax."
  @spec parse!(String.t()) :: ast()
  def parse!(source) do
    source
    |> Lexer.tokenize()
    |> parse_level(0)
    |> case do
      {ast, []} ->
        ast

      {_ast, rest} ->
        raise CompileError,
          description: "unexpected trailing tokens in expression: #{inspect(rest)}"
    end
  end

  @doc "How tightly binary operator `op` binds: a higher number binds tighter."
  @spec precedence(Ops.operator()) :: non_neg_integer()
  def precedence(op), do: Map.fetch!(@precedence, op)

  @doc "`ast` and every expression nested inside it, outermost first."
  @spec subexpressions(ast()) :: [ast()]
  def subexpressions(ast), do: [ast | Enum.flat_map(children(ast), &subexpressions/1)]

  defp children({:field, base, _field}), do: [base]
  defp children({:call, _name, args}), do: args
  defp children({:not, operand}), do: [operand]
  defp children({:neg, operand}), do: [operand]
  defp children({:binop, _op, left, right}), do: [left, right]
  defp children(_leaf), do: []

  # -- precedence-climbing parser ----------------------------------------

  defp parse_level(tokens, @unary_level), do: parse_unary(tokens)

  defp parse_level(tokens, level) do
    {left, rest} = parse_level(tokens, level + 1)
    chain(rest, left, level)
  end

  defp chain([{:op, op} | rest] = tokens, left, level) do
    if Map.get(@precedence, op) == level do
      {right, rest2} = parse_level(rest, level + 1)
      chain(rest2, {:binop, op, left, right}, level)
    else
      {left, tokens}
    end
  end

  defp chain(tokens, left, _level), do: {left, tokens}

  defp parse_unary([{:op, :not} | rest]) do
    {operand, rest2} = parse_unary(rest)
    {{:not, operand}, rest2}
  end

  defp parse_unary([{:op, :-} | rest]) do
    {operand, rest2} = parse_unary(rest)
    {{:neg, operand}, rest2}
  end

  defp parse_unary(tokens), do: tokens |> parse_primary() |> parse_postfix()

  defp parse_postfix({ast, [:dot, {:ident, field} | rest]}) do
    parse_postfix({{:field, ast, field}, rest})
  end

  defp parse_postfix(result), do: result

  defp parse_primary([{:num, number} | rest]), do: {number, rest}
  defp parse_primary([{:str, string} | rest]), do: {string, rest}
  defp parse_primary([{:bool, boolean} | rest]), do: {boolean, rest}
  defp parse_primary([{:var, name} | rest]), do: {{:var, name}, rest}

  defp parse_primary([:lparen | rest]) do
    {inner, rest2} = parse_level(rest, 0)

    case rest2 do
      [:rparen | rest3] -> {inner, rest3}
      _ -> raise CompileError, description: "expected closing parenthesis in expression"
    end
  end

  # Whether the function exists is checked by the caller, which knows the host's declared list.
  defp parse_primary([{:ident, name}, :lparen | rest]) do
    {args, rest2} = parse_args(rest, [])
    {{:call, name, args}, rest2}
  end

  defp parse_primary([{:ident, name} | _rest]) do
    raise CompileError,
      description:
        "unknown identifier #{name} in expression (variables start with $, strings are quoted)"
  end

  defp parse_primary(other) do
    raise CompileError, description: "unexpected token(s) in expression: #{inspect(other)}"
  end

  defp parse_args([:rparen | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_args(tokens, acc) do
    {arg, rest} = parse_level(tokens, 0)

    case rest do
      [:comma | rest2] -> parse_args(rest2, [arg | acc])
      [:rparen | rest2] -> {Enum.reverse([arg | acc]), rest2}
      _ -> raise CompileError, description: "expected , or ) in function call arguments"
    end
  end
end
