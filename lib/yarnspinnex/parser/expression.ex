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

  @spec parse!(String.t()) :: ast()
  def parse!(source) do
    source
    |> Lexer.tokenize()
    |> parse_expression()
    |> case do
      {ast, []} ->
        ast

      {_ast, rest} ->
        raise CompileError,
          description: "unexpected trailing tokens in expression: #{inspect(rest)}"
    end
  end

  # -- precedence-climbing parser ----------------------------------------

  # Lowest precedence first: `xor`, then `or`, `and`, equality, ordering, additive, multiplicative.
  defp parse_expression(tokens) do
    {left, rest} = parse_or(tokens)
    chain(rest, left, [:xor], &parse_or/1)
  end

  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)
    chain(rest, left, [:or], &parse_and/1)
  end

  defp parse_and(tokens) do
    {left, rest} = parse_equality(tokens)
    chain(rest, left, [:and], &parse_equality/1)
  end

  defp parse_equality(tokens) do
    {left, rest} = parse_relational(tokens)
    chain(rest, left, [:==, :!=], &parse_relational/1)
  end

  defp parse_relational(tokens) do
    {left, rest} = parse_additive(tokens)
    chain(rest, left, [:<, :>, :<=, :>=], &parse_additive/1)
  end

  defp parse_additive(tokens) do
    {left, rest} = parse_multiplicative(tokens)
    chain(rest, left, [:+, :-], &parse_multiplicative/1)
  end

  defp parse_multiplicative(tokens) do
    {left, rest} = parse_unary(tokens)
    chain(rest, left, [:*, :/, :%], &parse_unary/1)
  end

  defp chain([{:op, op} | rest] = tokens, left, allowed, next_fn) do
    if op in allowed do
      {right, rest2} = next_fn.(rest)
      chain(rest2, {:binop, op, left, right}, allowed, next_fn)
    else
      {left, tokens}
    end
  end

  defp chain(tokens, left, _allowed, _next_fn), do: {left, tokens}

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
    {inner, rest2} = parse_expression(rest)

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
    {arg, rest} = parse_expression(tokens)

    case rest do
      [:comma | rest2] -> parse_args(rest2, [arg | acc])
      [:rparen | rest2] -> {Enum.reverse([arg | acc]), rest2}
      _ -> raise CompileError, description: "expected , or ) in function call arguments"
    end
  end
end
