defmodule Yarnspinnex.Parser.Body do
  @moduledoc """
  Parses the lines inside one Yarn node (between `---` and `===`) into a tree of statements
  consumed by `Yarnspinnex.Interpreter`. Every statement and option ends with the source line it
  came from; consecutive `->` options are folded into one `{:options, ...}` statement.
  """

  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Parser.Expression

  @typedoc "A raw source line paired with its 1-based line number."
  @type source_line :: {String.t(), pos_integer()}

  @typedoc "What the compiler validates each expression against: known calls and context-owned names."
  @type opts :: %{
          calls: %{optional(String.t()) => non_neg_integer()},
          context: MapSet.t(String.t())
        }

  @typedoc "The 1-based source line a statement was parsed from."
  @type line :: pos_integer()

  @typedoc "One piece of a line or option label: literal text or an interpolated `{expression}`."
  @type part :: {:text, String.t()} | {:expr, Expression.ast()}

  @typedoc "The `#tags` written after a line or option, without their `#`."
  @type tags :: [String.t()]

  @type option :: {:option, [part()], Expression.ast() | nil, [statement()], tags(), line()}

  @type branch :: {Expression.ast(), [statement()]}

  @type statement ::
          {:line, String.t() | nil, [part()], tags(), line()}
          | {:options, [option()], line()}
          | {:set, String.t(), Expression.ast(), line()}
          | {:declare, String.t(), Expression.ast(), line()}
          | {:jump, String.t(), line()}
          | {:stop, line()}
          | {:if, [branch()], [statement()], line()}
          | {:command, String.t(), [Expression.ast()], line()}

  @node_name_re ~r/^[A-Za-z_]\w*$/
  @shorthand_jump_re ~r/^\[\[\s*([A-Za-z_]\w*)\s*\]\]$/
  @shorthand_jump_text_re ~r/^\[\[(.+?)\|\s*([A-Za-z_]\w*)\s*\]\]$/
  @option_if_re ~r/^(.*?)\s*<<\s*if\s+(.+?)\s*>>\s*$/
  @declare_type_re ~r/\s+as\s+\w+$/
  # Everything before the first `: ` names the speaker, as in Yarn Spinner; a `\:` anywhere before
  # it keeps the line from being read that way.
  @speaker_re ~r/^([^:{}\[\]<>\\]+?):\s+(.*)$/su
  @tags_re ~r/^(.*?)((?:\s+#\S+)+)$/
  @compound_operators %{?+ => :+, ?- => :-, ?* => :*, ?/ => :/, ?% => :%}
  @directive_keywords ~w(if elseif else endif set declare jump stop)

  @spec parse([source_line()], opts()) :: [statement()]
  def parse(raw_lines, opts) do
    case parse_statements(preprocess(raw_lines), 0, opts) do
      {statements, []} ->
        statements

      {_statements, [%{text: text, line: line} | _]} ->
        raise CompileError,
          line: line,
          description: "unexpected or unmatched control statement: #{text}"
    end
  end

  # -- preprocessing ------------------------------------------------------

  defp preprocess(raw_lines) do
    raw_lines
    |> Enum.map(fn {text, number} -> {strip_comment(text), number} end)
    |> Enum.reject(fn {text, _number} -> String.trim(text) == "" end)
    |> Enum.map(fn {text, number} ->
      %{line: number, indent: indent_of(text), text: String.trim(text)}
    end)
  end

  defp indent_of(line), do: indent_of(line, 0)

  defp indent_of(<<byte, rest::binary>>, acc) when byte in [?\s, ?\t],
    do: indent_of(rest, acc + 1)

  defp indent_of(_line, acc), do: acc

  defp strip_comment(line) do
    case find_comment_start(String.graphemes(line), 0, false) do
      nil -> line
      idx -> String.slice(line, 0, idx)
    end
  end

  defp find_comment_start([], _idx, _in_str), do: nil

  defp find_comment_start(["\"" | rest], idx, in_str),
    do: find_comment_start(rest, idx + 1, not in_str)

  defp find_comment_start(["/", "/" | _rest], idx, false), do: idx

  defp find_comment_start([_grapheme | rest], idx, in_str) do
    find_comment_start(rest, idx + 1, in_str)
  end

  # Splits `Sally: Hi. #line:abc #happy` into `{"Sally: Hi.", ["line:abc", "happy"]}`.
  defp split_trailing_tags(text) do
    case Regex.run(@tags_re, text) do
      [_, before, tags] ->
        {String.trim(before), tags |> String.split() |> Enum.map(&String.trim_leading(&1, "#"))}

      nil ->
        {text, []}
    end
  end

  # -- statement parsing ----------------------------------------------------

  defp parse_statements(lines, min_indent, opts), do: do_parse(lines, min_indent, opts, [])

  defp do_parse([], _min_indent, _opts, acc), do: {finish(acc), []}

  defp do_parse([%{indent: indent} | _] = lines, min_indent, _opts, acc)
       when indent < min_indent do
    {finish(acc), lines}
  end

  defp do_parse([%{text: text} | _] = lines, min_indent, opts, acc) do
    if control_stop?(text) do
      {finish(acc), lines}
    else
      {statement, rest} = parse_one(lines, opts)
      do_parse(rest, min_indent, opts, [statement | acc])
    end
  end

  # Reverses the accumulated statements and folds each run of `->` options into one group.
  defp finish(acc) do
    acc
    |> Enum.reverse()
    |> Enum.chunk_by(&match?({:option, _, _, _, _, _}, &1))
    |> Enum.flat_map(fn
      [{:option, _, _, _, _, line} | _] = group -> [{:options, group, line}]
      others -> others
    end)
  end

  # `<<else>>`, `<<endif>>`, and a well-formed `<<elseif ...>>` end the statement list they sit in.
  defp control_stop?("<<" <> _ = text) do
    case directive(text) do
      {:ok, "else", ""} -> true
      {:ok, "endif", ""} -> true
      {:ok, "elseif", condition} when condition != "" -> true
      _other -> false
    end
  end

  defp control_stop?(_text), do: false

  # Any error raised while parsing a statement is located at that statement's line.
  defp parse_one([%{line: line} | _] = lines, opts) do
    dispatch(lines, opts)
  rescue
    error in CompileError -> reraise %{error | line: error.line || line}, __STACKTRACE__
  end

  defp dispatch([%{text: "->" <> _} = current | rest], opts),
    do: parse_option(current, rest, opts)

  defp dispatch([%{text: "<<" <> _ = text, line: line} | rest], opts) do
    parse_control(text, rest, opts, line)
  end

  defp dispatch([%{text: "[[" <> _ = text, line: line} | rest], opts) do
    {parse_shorthand_jump(text, opts, line), rest}
  end

  defp dispatch([%{text: text, line: line} | rest], opts),
    do: {parse_line(text, opts, line), rest}

  # -- directives -------------------------------------------------------------

  # Splits `<< set $x = 1 >>` into `{:ok, "set", "$x = 1"}`; without the closing marker, `:error`.
  defp directive("<<" <> inner) do
    if String.ends_with?(inner, ">>") do
      body = inner |> binary_part(0, byte_size(inner) - 2) |> String.trim()
      {keyword, args} = split_word(body)
      {:ok, keyword, args}
    else
      :error
    end
  end

  # Takes the leading identifier off `text`, returning it with the trimmed remainder.
  defp split_word(text), do: split_word(text, [])

  defp split_word(<<byte, rest::binary>>, acc)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_ do
    split_word(rest, [byte | acc])
  end

  defp split_word(rest, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), String.trim(rest)}
  end

  defp parse_control(text, rest, opts, line) do
    case directive(text) do
      {:ok, "if", condition} when condition != "" -> parse_if(condition, rest, opts, line)
      {:ok, "set", args} -> {parse_set(args, text, opts, line), rest}
      {:ok, "declare", args} -> {parse_declare(args, text, opts, line), rest}
      {:ok, "jump", target} -> {parse_jump(target, text, line), rest}
      {:ok, "stop", ""} -> {{:stop, line}, rest}
      {:ok, keyword, _args} when keyword in @directive_keywords -> malformed(keyword, text)
      {:ok, name, args} when name != "" -> {parse_command(name, args, opts, line), rest}
      _other -> raise CompileError, description: "malformed statement: #{text}"
    end
  end

  defp malformed(keyword, text) do
    raise CompileError, description: "malformed <<#{keyword}>> statement: #{text}"
  end

  defp parse_if(condition, rest, opts, line) do
    cond_ast = parse_expr!(condition, opts)
    {then_body, rest} = parse_statements(rest, 0, opts)
    {elseif_branches, rest} = parse_elseifs(rest, opts)
    {else_body, rest} = parse_else(rest, opts)
    {{:if, [{cond_ast, then_body} | elseif_branches], else_body, line}, expect_endif(rest)}
  end

  defp parse_elseifs([%{text: text, line: line} | rest] = lines, opts) do
    case directive(text) do
      {:ok, "elseif", condition} when condition != "" ->
        cond_ast = parse_expression(condition, line, opts)
        {body, rest} = parse_statements(rest, 0, opts)
        {more, rest} = parse_elseifs(rest, opts)
        {[{cond_ast, body} | more], rest}

      _other ->
        {[], lines}
    end
  end

  defp parse_elseifs([], _opts), do: {[], []}

  defp parse_else([%{text: text} | rest] = lines, opts) do
    case directive(text) do
      {:ok, "else", ""} -> parse_statements(rest, 0, opts)
      _other -> {[], lines}
    end
  end

  defp parse_else([], _opts), do: {[], []}

  defp expect_endif([%{text: text, line: line} | rest]) do
    case directive(text) do
      {:ok, "endif", ""} -> rest
      _other -> raise CompileError, line: line, description: "expected <<endif>>, got: #{text}"
    end
  end

  defp expect_endif([]) do
    raise CompileError, description: "expected <<endif>>, reached end of node"
  end

  defp parse_expression(source, line, opts) do
    parse_expr!(source, opts)
  rescue
    error in CompileError -> reraise %{error | line: line}, __STACKTRACE__
  end

  # `$name = expr`, `$name to expr`, or `$name += expr` (and the other arithmetic operators).
  defp parse_set(args, text, opts, line) do
    with {:ok, var, rest} <- variable_name(args),
         {:ok, operator, expr_src} <- assignment(rest) do
      var = check_writable!(var, opts)
      value = parse_expr!(expr_src, opts)

      case operator do
        nil -> {:set, var, value, line}
        op -> {:set, var, {:binop, op, {:var, var}, value}, line}
      end
    else
      :error -> malformed("set", text)
    end
  end

  # `$name = expr`, optionally followed by `as type`, which is accepted and ignored.
  defp parse_declare(args, text, opts, line) do
    with {:ok, var, rest} <- variable_name(args),
         {:ok, nil, expr_src} <- assignment(rest) do
      expr_src = Regex.replace(@declare_type_re, expr_src, "")
      {:declare, check_writable!(var, opts), parse_expr!(expr_src, opts), line}
    else
      _other -> malformed("declare", text)
    end
  end

  defp parse_jump(target, text, line) do
    if Regex.match?(@node_name_re, target) do
      {:jump, target, line}
    else
      malformed("jump", text)
    end
  end

  defp variable_name(<<?$, first, _::binary>> = text)
       when first in ?a..?z or first in ?A..?Z or first == ?_ do
    {name, rest} = text |> binary_part(1, byte_size(text) - 1) |> split_word()
    {:ok, name, rest}
  end

  defp variable_name(_text), do: :error

  defp assignment("to " <> expr), do: nonempty(nil, String.trim(expr))
  defp assignment("=" <> expr), do: nonempty(nil, String.trim(expr))

  defp assignment(<<operator, ?=, expr::binary>>) when operator in [?+, ?-, ?*, ?/, ?%] do
    nonempty(Map.fetch!(@compound_operators, operator), String.trim(expr))
  end

  defp assignment(_other), do: :error

  defp nonempty(_operator, ""), do: :error
  defp nonempty(operator, expr), do: {:ok, operator, expr}

  # Context wins at runtime, so a script that writes a context-owned name is always a mistake.
  defp check_writable!(var, opts) do
    if MapSet.member?(opts.context, var) do
      raise CompileError,
        description: "cannot assign to $#{var}: the host context owns that name"
    end

    var
  end

  # -- options ------------------------------------------------------------------

  defp parse_option(%{indent: indent, text: text, line: line}, rest, opts) do
    {body_text, tags} =
      text |> String.trim_leading("->") |> String.trim() |> split_trailing_tags()

    {label, condition_ast} =
      case Regex.run(@option_if_re, body_text) do
        [_, label, cond_src] -> {label, parse_expr!(cond_src, opts)}
        nil -> {body_text, nil}
      end

    {nested, remaining} = parse_statements(rest, indent + 1, opts)
    {{:option, parse_interpolated(label, opts), condition_ast, nested, tags, line}, remaining}
  end

  defp parse_shorthand_jump(text, opts, line) do
    cond do
      match = Regex.run(@shorthand_jump_re, text) ->
        [_, target] = match
        {:jump, target, line}

      match = Regex.run(@shorthand_jump_text_re, text) ->
        [_, label, target] = match
        parts = parse_interpolated(String.trim(label), opts)
        {:option, parts, nil, [{:jump, target, line}], [], line}

      true ->
        raise CompileError, description: "malformed shorthand jump: #{text}"
    end
  end

  # -- commands -------------------------------------------------------------

  defp parse_command(name, args, opts, line) do
    {:command, name, args |> tokenize_args() |> Enum.map(&compile_arg(&1, opts)), line}
  end

  defp tokenize_args(source), do: split_args(source, 0, [], [])

  # Splits on whitespace outside quotes and braces, so `"two words"` and `{$gold + 1}` stay whole.
  defp split_args(<<>>, 0, current, acc), do: Enum.reverse(push_arg(current, acc))

  defp split_args(<<>>, _depth, _current, _acc) do
    raise CompileError, description: "unterminated { in command"
  end

  defp split_args(<<byte, rest::binary>>, 0, current, acc) when byte in [?\s, ?\t] do
    split_args(rest, 0, [], push_arg(current, acc))
  end

  defp split_args(<<?", rest::binary>>, depth, current, acc) do
    {quoted, rest} = take_quoted(rest, [?"])
    split_args(rest, depth, quoted ++ current, acc)
  end

  defp split_args(<<?{, rest::binary>>, depth, current, acc) do
    split_args(rest, depth + 1, [?{ | current], acc)
  end

  defp split_args(<<?}, rest::binary>>, depth, current, acc) when depth > 0 do
    split_args(rest, depth - 1, [?} | current], acc)
  end

  defp split_args(<<byte, rest::binary>>, depth, current, acc) do
    split_args(rest, depth, [byte | current], acc)
  end

  defp push_arg([], acc), do: acc
  defp push_arg(current, acc), do: [current |> Enum.reverse() |> IO.iodata_to_binary() | acc]

  defp take_quoted(<<?\\, byte, rest::binary>>, acc), do: take_quoted(rest, [byte, ?\\ | acc])
  defp take_quoted(<<?", rest::binary>>, acc), do: {[?" | acc], rest}
  defp take_quoted(<<byte, rest::binary>>, acc), do: take_quoted(rest, [byte | acc])

  defp take_quoted(<<>>, _acc) do
    raise CompileError, description: "unterminated string in command"
  end

  # `{expression}` is evaluated; a quoted or bare word that isn't an expression is passed as text.
  defp compile_arg("{" <> _ = token, opts) do
    if String.ends_with?(token, "}") do
      parse_expr!(binary_part(token, 1, byte_size(token) - 2), opts)
    else
      raise CompileError, description: "malformed command argument: #{token}"
    end
  end

  defp compile_arg(token, opts) do
    parse_expr!(token, opts)
  rescue
    CompileError -> token
  end

  # -- lines --------------------------------------------------------------------

  defp parse_line(text, opts, line) do
    {text, tags} = split_trailing_tags(text)
    {speaker, rest} = extract_speaker(text)
    {:line, speaker, parse_interpolated(rest, opts), tags, line}
  end

  defp extract_speaker(text) do
    case Regex.run(@speaker_re, text) do
      [_, speaker, rest] -> {String.trim(speaker), rest}
      nil -> {nil, text}
    end
  end

  # -- expression validation ------------------------------------------------

  defp parse_expr!(source, opts) do
    ast = Expression.parse!(source)
    check_calls!(ast, opts)
    ast
  end

  defp check_calls!({:call, name, args}, opts) do
    case Map.fetch(opts.calls, name) do
      {:ok, arity} when length(args) == arity ->
        :ok

      {:ok, arity} ->
        raise CompileError,
          description: "#{name} takes #{arity} argument(s), given #{length(args)}"

      :error ->
        raise CompileError, description: "unknown or unsupported yarn function: #{name}"
    end

    Enum.each(args, &check_calls!(&1, opts))
  end

  defp check_calls!({:binop, _op, left, right}, opts) do
    check_calls!(left, opts)
    check_calls!(right, opts)
  end

  defp check_calls!({:field, base, _field}, opts), do: check_calls!(base, opts)
  defp check_calls!({:not, expr}, opts), do: check_calls!(expr, opts)
  defp check_calls!({:neg, expr}, opts), do: check_calls!(expr, opts)
  defp check_calls!(_leaf, _opts), do: :ok

  # -- interpolated text (used for both lines and option labels) ----------

  defp parse_interpolated(text, opts) do
    text
    |> String.graphemes()
    |> scan_text([], [], opts)
  end

  defp scan_text([], text_acc, parts, _opts), do: finish_text(text_acc, parts) |> Enum.reverse()

  defp scan_text(["\\", "{" | rest], text_acc, parts, opts),
    do: scan_text(rest, ["{" | text_acc], parts, opts)

  defp scan_text(["\\", "}" | rest], text_acc, parts, opts),
    do: scan_text(rest, ["}" | text_acc], parts, opts)

  defp scan_text(["\\", ":" | rest], text_acc, parts, opts),
    do: scan_text(rest, [":" | text_acc], parts, opts)

  defp scan_text(["{" | rest], text_acc, parts, opts) do
    parts = finish_text(text_acc, parts)
    {expr_src, rest2} = read_expr(rest, 1, [])
    scan_text(rest2, [], [{:expr, parse_expr!(expr_src, opts)} | parts], opts)
  end

  defp scan_text([grapheme | rest], text_acc, parts, opts),
    do: scan_text(rest, [grapheme | text_acc], parts, opts)

  defp finish_text([], parts), do: parts
  defp finish_text(acc, parts), do: [{:text, acc |> Enum.reverse() |> Enum.join()} | parts]

  defp read_expr(["\"" | rest], depth, acc) do
    {str_chars, rest2} = read_string_raw(rest, ["\""])
    read_expr(rest2, depth, str_chars ++ acc)
  end

  defp read_expr(["{" | rest], depth, acc), do: read_expr(rest, depth + 1, ["{" | acc])
  defp read_expr(["}" | rest], 1, acc), do: {acc |> Enum.reverse() |> Enum.join(), rest}
  defp read_expr(["}" | rest], depth, acc), do: read_expr(rest, depth - 1, ["}" | acc])
  defp read_expr([grapheme | rest], depth, acc), do: read_expr(rest, depth, [grapheme | acc])

  defp read_expr([], _depth, _acc) do
    raise CompileError, description: "unterminated { in line"
  end

  defp read_string_raw(["\\", grapheme | rest], acc) do
    read_string_raw(rest, [grapheme, "\\" | acc])
  end

  defp read_string_raw(["\"" | rest], acc), do: {["\"" | acc], rest}
  defp read_string_raw([grapheme | rest], acc), do: read_string_raw(rest, [grapheme | acc])

  defp read_string_raw([], _acc) do
    raise CompileError, description: "unterminated string in line"
  end
end
