defmodule Yarnspinnex.Parser do
  @moduledoc """
  Splits a Yarn source string into nodes (`title: ...` header, `---` body
  separator, `===` terminator) and parses each node's body.
  """

  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Node
  alias Yarnspinnex.Parser.Body

  @default_opts %{calls: Yarnspinnex.Functions.builtins(), context: MapSet.new()}

  @doc false
  @spec parse(String.t(), Body.opts()) :: {:ok, [Node.t()]} | {:error, CompileError.t()}
  def parse(source, opts \\ @default_opts) when is_binary(source) do
    nodes =
      source
      |> String.replace_prefix("\uFEFF", "")
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> split_nodes()
      |> Enum.map(&parse_node(&1, opts))

    {:ok, nodes}
  rescue
    error in CompileError -> {:error, error}
  end

  # Groups numbered source lines into `{header_lines, body_lines}` per node.
  defp split_nodes(lines) do
    {state, nodes} = Enum.reduce(lines, {:seeking, []}, &split_line/2)

    case state do
      :seeking ->
        Enum.reverse(nodes)

      {:header, {_text, line}, _header} ->
        raise CompileError, line: line, description: "node missing --- separator"

      {:body, {_text, line}, _header, _body} ->
        raise CompileError, line: line, description: "node missing closing === marker"
    end
  end

  defp split_line({text, _number} = line, {state, nodes}) do
    case {state, String.trim(text)} do
      {:seeking, ""} ->
        {:seeking, nodes}

      {:seeking, _} ->
        {{:header, line, [line]}, nodes}

      {{:header, first, header}, "---"} ->
        {{:body, first, header, []}, nodes}

      {{:header, first, header}, _} ->
        {{:header, first, [line | header]}, nodes}

      {{:body, _first, header, body}, "==="} ->
        {:seeking, [{Enum.reverse(header), Enum.reverse(body)} | nodes]}

      {{:body, first, header, body}, _} ->
        {{:body, first, header, [line | body]}, nodes}
    end
  end

  defp parse_node({[{_text, first_line} | _] = header_lines, body_lines}, opts) do
    headers = parse_headers(header_lines)

    case Map.fetch(headers, "title") do
      {:ok, title} ->
        %Node{
          title: title,
          line: first_line,
          headers: headers,
          body: parse_body(body_lines, title, opts)
        }

      :error ->
        raise CompileError, line: first_line, description: "node missing title header"
    end
  end

  defp parse_body(lines, title, opts) do
    Body.parse(lines, opts)
  rescue
    error in CompileError -> reraise %{error | node: title}, __STACKTRACE__
  end

  defp parse_headers(lines) do
    lines
    |> Enum.map(fn {text, _number} -> text end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Map.new(&parse_header_line/1)
  end

  defp parse_header_line(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> {String.trim(key), String.trim(value)}
      [key] -> {String.trim(key), ""}
    end
  end
end
