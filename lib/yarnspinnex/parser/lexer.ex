defmodule Yarnspinnex.Parser.Lexer do
  @moduledoc """
  Tokenizes a Yarn expression source string. Pure source-to-tokens - no
  knowledge of expression grammar or the AST; that lives in
  `Yarnspinnex.Parser.Expression`.
  """

  alias Yarnspinnex.CompileError

  @type token ::
          {:num, number()}
          | {:str, String.t()}
          | {:bool, boolean()}
          | {:var, String.t()}
          | {:ident, String.t()}
          | {:op, atom()}
          | :lparen
          | :rparen
          | :comma
          | :dot

  # Yarn's word forms of the operators, accepted alongside the symbols.
  @keyword_operators %{
    "and" => :and,
    "or" => :or,
    "not" => :not,
    "xor" => :xor,
    "is" => :==,
    "eq" => :==,
    "neq" => :!=,
    "lt" => :<,
    "gt" => :>,
    "lte" => :<=,
    "gte" => :>=
  }

  @spec tokenize(String.t()) :: [token()]
  def tokenize(source) do
    source
    |> String.to_charlist()
    |> do_tokenize([])
    |> Enum.reverse()
  end

  defp do_tokenize([], acc), do: acc

  defp do_tokenize([char | rest], acc) when char in [?\s, ?\t, ?\n, ?\r] do
    do_tokenize(rest, acc)
  end

  defp do_tokenize([?" | rest], acc) do
    {string, rest2} = read_string(rest, [])
    do_tokenize(rest2, [{:str, string} | acc])
  end

  # The sigil is source syntax only; `$player` and the host's `player:` are the same name.
  defp do_tokenize([?$, char | rest], acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    {name, rest2} = read_ident([char | rest], [])
    do_tokenize(rest2, [{:var, name} | acc])
  end

  defp do_tokenize([?$ | _rest], _acc) do
    raise CompileError, description: "expected a variable name after $"
  end

  defp do_tokenize([char | _] = chars, acc) when char in ?0..?9 do
    {number, rest} = read_number(chars, [], false)
    do_tokenize(rest, [{:num, number} | acc])
  end

  defp do_tokenize([char | _] = chars, acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    {ident, rest} = read_ident(chars, [])
    do_tokenize(rest, [ident_token(ident) | acc])
  end

  defp do_tokenize([?=, ?= | rest], acc), do: do_tokenize(rest, [{:op, :==} | acc])
  defp do_tokenize([?!, ?= | rest], acc), do: do_tokenize(rest, [{:op, :!=} | acc])
  defp do_tokenize([?<, ?= | rest], acc), do: do_tokenize(rest, [{:op, :<=} | acc])
  defp do_tokenize([?>, ?= | rest], acc), do: do_tokenize(rest, [{:op, :>=} | acc])
  defp do_tokenize([?&, ?& | rest], acc), do: do_tokenize(rest, [{:op, :and} | acc])
  defp do_tokenize([?|, ?| | rest], acc), do: do_tokenize(rest, [{:op, :or} | acc])
  defp do_tokenize([?^ | rest], acc), do: do_tokenize(rest, [{:op, :xor} | acc])
  defp do_tokenize([?! | rest], acc), do: do_tokenize(rest, [{:op, :not} | acc])
  defp do_tokenize([?+ | rest], acc), do: do_tokenize(rest, [{:op, :+} | acc])
  defp do_tokenize([?- | rest], acc), do: do_tokenize(rest, [{:op, :-} | acc])
  defp do_tokenize([?* | rest], acc), do: do_tokenize(rest, [{:op, :*} | acc])
  defp do_tokenize([?/ | rest], acc), do: do_tokenize(rest, [{:op, :/} | acc])
  defp do_tokenize([?% | rest], acc), do: do_tokenize(rest, [{:op, :%} | acc])
  defp do_tokenize([?< | rest], acc), do: do_tokenize(rest, [{:op, :<} | acc])
  defp do_tokenize([?> | rest], acc), do: do_tokenize(rest, [{:op, :>} | acc])
  defp do_tokenize([?( | rest], acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize([?) | rest], acc), do: do_tokenize(rest, [:rparen | acc])
  defp do_tokenize([?, | rest], acc), do: do_tokenize(rest, [:comma | acc])
  defp do_tokenize([?. | rest], acc), do: do_tokenize(rest, [:dot | acc])

  defp do_tokenize([char | _], _acc) do
    raise CompileError, description: "unexpected character #{<<char::utf8>>} in expression"
  end

  defp ident_token("true"), do: {:bool, true}
  defp ident_token("false"), do: {:bool, false}

  defp ident_token(word) do
    case Map.fetch(@keyword_operators, word) do
      {:ok, op} -> {:op, op}
      :error -> {:ident, word}
    end
  end

  defp read_ident(chars, acc) do
    case chars do
      [char | rest] when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_ ->
        read_ident(rest, [char | acc])

      rest ->
        {acc |> Enum.reverse() |> List.to_string(), rest}
    end
  end

  defp read_number(chars, acc, seen_dot?) do
    case chars do
      [char | rest] when char in ?0..?9 ->
        read_number(rest, [char | acc], seen_dot?)

      [?., char | rest] when char in ?0..?9 and not seen_dot? ->
        read_number(rest, [char, ?. | acc], true)

      rest ->
        text = acc |> Enum.reverse() |> List.to_string()
        number = if seen_dot?, do: String.to_float(text), else: String.to_integer(text)
        {number, rest}
    end
  end

  defp read_string([?\\, char | rest], acc), do: read_string(rest, [unescape(char) | acc])
  defp read_string([?" | rest], acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp read_string([char | rest], acc), do: read_string(rest, [char | acc])

  defp read_string([], _acc) do
    raise CompileError, description: "unterminated string in expression"
  end

  defp unescape(?n), do: ?\n
  defp unescape(?t), do: ?\t
  defp unescape(char), do: char
end
