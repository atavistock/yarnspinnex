defmodule Yarnspinnex.Mermaid do
  @moduledoc """
  Renders a compiled script as Mermaid flowchart source: `node_graph/1` draws one box per node
  with an edge per `<<jump>>`, and `flowchart/2` draws every line, choice, and branch inside
  each node with edges following control flow between them.
  """

  alias Yarnspinnex.Node
  alias Yarnspinnex.Parser.Expression
  alias Yarnspinnex.Script

  @done_id "done"
  @done_label "end"

  @precedence %{
    xor: 0,
    or: 1,
    and: 2,
    ==: 3,
    !=: 3,
    <: 4,
    >: 4,
    <=: 4,
    >=: 4,
    +: 5,
    -: 5,
    *: 6,
    /: 6,
    %: 6
  }

  @typep state :: %{
           prefix: String.t(),
           counter: non_neg_integer(),
           shapes: [String.t()],
           edges: [String.t()]
         }

  @doc "One box per node, one edge per jump, the start node drawn as a stadium."
  @spec node_graph(Script.t()) :: String.t()
  def node_graph(%Script{} = script) do
    nodes = ordered_nodes(script)

    shapes =
      Enum.map(nodes, fn node ->
        if node.title == script.start_title,
          do: ~s(  #{node_id(node.title)}\(["#{escape(node.title)}"]\)),
          else: ~s(  #{node_id(node.title)}["#{escape(node.title)}"])
      end)

    edges =
      for node <- nodes,
          {target, _line} <- Yarnspinnex.Analysis.jump_targets(node.body),
          uniq: true,
          do: "  #{node_id(node.title)} --> #{node_id(target)}"

    Enum.join(["flowchart TD" | shapes ++ edges], "\n")
  end

  @doc """
  Every statement drawn inside a subgraph per node. Consecutive lines, sets, and commands share
  one box; options and `<<if>>` fan out on labeled edges; `<<stop>>` and the end of a node lead
  to a shared terminal. Pass `nodes: [titles]` to draw only those nodes, with jumps out of the
  set landing on a plain box for the target.
  """
  @spec flowchart(Script.t(), nodes: [String.t()]) :: String.t()
  def flowchart(%Script{} = script, opts \\ []) do
    nodes = ordered_nodes(script)
    titles = Keyword.get(opts, :nodes)
    chosen = if titles, do: Enum.filter(nodes, &(&1.title in titles)), else: nodes
    chosen_titles = MapSet.new(chosen, & &1.title)

    {subgraphs, edges} =
      Enum.map_reduce(chosen, [], fn node, edges ->
        state = render_node(node)
        {subgraph(node, state), edges ++ Enum.reverse(state.edges)}
      end)

    externals =
      for node <- chosen,
          {target, _line} <- Yarnspinnex.Analysis.jump_targets(node.body),
          target not in chosen_titles,
          uniq: true,
          do: ~s(  #{entry_id(target)}["#{escape(target)}"])

    terminal =
      if Enum.any?(edges, &String.ends_with?(&1, " #{@done_id}")),
        do: [~s(  #{@done_id}\(\("#{@done_label}"\)\))],
        else: []

    Enum.join(["flowchart TD" | List.flatten(subgraphs) ++ externals ++ terminal ++ edges], "\n")
  end

  defp ordered_nodes(%Script{nodes: nodes, start_title: start}) do
    nodes
    |> Map.values()
    |> Enum.sort_by(&{&1.title != start, &1.title})
  end

  defp node_id(title), do: "n_" <> title

  defp entry_id(title), do: node_id(title) <> "_1"

  # Statement ids are `n_<title>_<counter>`, so the subgraph takes a different prefix: a node
  # titled `A_1` must not share an id with the first statement of node `A`.
  defp subgraph(%Node{title: title}, state) do
    [~s(  subgraph sg_#{title}["#{escape(title)}"])] ++
      Enum.reverse(state.shapes) ++ ["  end"]
  end

  @spec render_node(Node.t()) :: state()
  defp render_node(%Node{title: title, body: body}) do
    state = %{prefix: node_id(title), counter: 0, shapes: [], edges: []}

    case body do
      [] ->
        {id, state} = next_id(state)
        state |> shape(~s(#{id}["#{escape(title)}"])) |> edge(id, @done_id)

      statements ->
        {_entry, state} = render_body(statements, state, @done_id)
        state
    end
  end

  # Renders a statement list whose exit flows to `next`, returning the id control enters at.
  # Ids for every chunk are reserved before any chunk renders so the first chunk of a node body
  # is always `<node>_1`, which jumps from other nodes point at.
  defp render_body(statements, state, next) do
    chunks = chunk(statements)
    {ids, state} = Enum.map_reduce(chunks, state, fn _chunk, state -> next_id(state) end)
    nexts = tl(ids) ++ [next]

    state =
      [chunks, ids, nexts]
      |> Enum.zip()
      |> Enum.reduce(state, fn {chunk, id, next}, state ->
        render_chunk(chunk, id, state, next)
      end)

    {hd(ids), state}
  end

  # Consecutive linear statements collapse into one chunk; a jump or stop closes it, and an
  # options block or `<<if>>` stands on its own.
  defp chunk(statements) do
    {chunks, pending} =
      Enum.reduce(statements, {[], []}, fn
        {:options, _, _} = statement, {chunks, pending} ->
          {[statement | flush(pending, chunks)], []}

        {:if, _, _, _} = statement, {chunks, pending} ->
          {[statement | flush(pending, chunks)], []}

        {:jump, _, _} = statement, {chunks, pending} ->
          {flush([statement | pending], chunks), []}

        {:stop, _} = statement, {chunks, pending} ->
          {flush([statement | pending], chunks), []}

        statement, {chunks, pending} ->
          {chunks, [statement | pending]}
      end)

    Enum.reverse(flush(pending, chunks))
  end

  defp flush([], chunks), do: chunks
  defp flush(pending, chunks), do: [{:linear, Enum.reverse(pending)} | chunks]

  defp render_chunk({:linear, statements}, id, state, next) do
    {terminator, shown} =
      case List.last(statements) do
        {:jump, _, _} = jump -> {jump, Enum.drop(statements, -1)}
        {:stop, _} = stop -> {stop, Enum.drop(statements, -1)}
        _other -> {nil, statements}
      end

    label =
      case shown do
        [] -> terminator_label(terminator)
        shown -> shown |> Enum.map(&statement_label/1) |> Enum.join("<br/>")
      end

    state = shape(state, ~s(#{id}["#{label}"]))

    case terminator do
      {:jump, target, _} -> edge(state, id, entry_id(target))
      {:stop, _} -> edge(state, id, @done_id)
      nil -> edge(state, id, next)
    end
  end

  defp render_chunk({:options, options, _line}, id, state, next) do
    state = shape(state, ~s(#{id}{{"choice"}}))

    Enum.reduce(options, state, fn {:option, parts, condition, body, _tags, _line}, state ->
      label = parts_label(parts) <> condition_suffix(condition)
      branch(state, id, label, body, next)
    end)
  end

  defp render_chunk({:if, branches, else_body, _line}, id, state, next) do
    state = shape(state, ~s(#{id}{"if"}))

    state =
      Enum.reduce(branches, state, fn {condition, body}, state ->
        branch(state, id, expression(condition), body, next)
      end)

    branch(state, id, "else", else_body, next)
  end

  defp branch(state, from, label, [], next), do: edge(state, from, next, label)

  defp branch(state, from, label, body, next) do
    {entry, state} = render_body(body, state, next)
    edge(state, from, entry, label)
  end

  defp terminator_label({:jump, target, _}), do: "jump " <> escape(target)
  defp terminator_label({:stop, _}), do: "stop"

  defp statement_label({:line, nil, parts, _tags, _line}), do: parts_label(parts)

  defp statement_label({:line, speaker, parts, _tags, _line}),
    do: escape(speaker) <> ": " <> parts_label(parts)

  defp statement_label({:set, var, expr, _line}), do: escape("$#{var} = ") <> expression(expr)

  defp statement_label({:declare, var, expr, _line}),
    do: escape("declare $#{var} = ") <> expression(expr)

  defp statement_label({:command, name, args, _line}) do
    escape("<<" <> Enum.join([name | Enum.map(args, &expression_text/1)], " ") <> ">>")
  end

  defp parts_label(parts) do
    Enum.map_join(parts, fn
      {:text, text} -> escape(text)
      {:expr, ast} -> escape("{" <> expression_text(ast) <> "}")
    end)
  end

  defp condition_suffix(nil), do: ""

  defp condition_suffix(condition),
    do: " " <> escape("<<if ") <> expression(condition) <> escape(">>")

  defp next_id(%{prefix: prefix, counter: counter} = state) do
    counter = counter + 1
    {"#{prefix}_#{counter}", %{state | counter: counter}}
  end

  defp shape(state, text), do: %{state | shapes: ["    " <> text | state.shapes]}

  defp edge(state, from, to), do: %{state | edges: ["  #{from} --> #{to}" | state.edges]}

  defp edge(state, from, to, label),
    do: %{state | edges: [~s(  #{from} -->|"#{label}"| #{to}) | state.edges]}

  @doc "Renders an expression AST back to Yarn source text."
  @spec expression_text(Expression.ast()) :: String.t()
  def expression_text(ast), do: print(ast, nil)

  defp expression(ast), do: escape(expression_text(ast))

  defp print(value, _parent) when is_binary(value), do: inspect(value)
  defp print(value, _parent) when is_number(value) or is_boolean(value), do: to_string(value)
  defp print({:var, name}, _parent), do: "$" <> name
  defp print({:field, base, field}, _parent), do: print(base, :postfix) <> "." <> field
  defp print({:not, operand}, _parent), do: "not " <> print(operand, :unary)
  defp print({:neg, operand}, _parent), do: "-" <> print(operand, :unary)

  defp print({:call, name, args}, _parent),
    do: name <> "(" <> Enum.map_join(args, ", ", &print(&1, nil)) <> ")"

  defp print({:binop, op, left, right} = ast, parent) do
    text = print(left, {op, :left}) <> " #{op} " <> print(right, {op, :right})
    if parenthesize?(ast, parent), do: "(" <> text <> ")", else: text
  end

  defp parenthesize?(_ast, nil), do: false
  defp parenthesize?(_ast, :unary), do: true
  defp parenthesize?(_ast, :postfix), do: true

  defp parenthesize?({:binop, op, _, _}, {parent_op, side}) do
    child = Map.fetch!(@precedence, op)
    parent = Map.fetch!(@precedence, parent_op)
    child < parent or (child == parent and side == :right)
  end

  # Mermaid reads a quoted label as HTML, so anything that could open a tag, an entity, or
  # Mermaid's own syntax is written as a numeric entity.
  @doc false
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("#", "#35;")
    |> String.replace("&", "#38;")
    |> String.replace("\"", "#34;")
    |> String.replace("<", "#60;")
    |> String.replace(">", "#62;")
    |> String.replace("{", "#123;")
    |> String.replace("}", "#125;")
    |> String.replace("[", "#91;")
    |> String.replace("]", "#93;")
    |> String.replace("|", "#124;")
    |> String.replace("(", "#40;")
    |> String.replace(")", "#41;")
  end
end
