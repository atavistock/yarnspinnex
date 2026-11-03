# Yarnspinnex

Compiles [Yarn Spinner](https://www.yarnspinner.dev/) dialogue into a `Yarnspinnex.Script` (plain data, safe to cache) and runs it one event at a time against a `Yarnspinnex.Cursor` (plain data, safe to persist). No processes.

```elixir
def deps do
  [{:yarnspinnex, github: "atavistock/yarnspinnex"}]
end
```

## Quick start

```yarn
title: Start
---
Sally: Hi there. How's it going?
-> Great, thanks!
    Sally: Glad to hear it.
-> Could be better...
    Sally: Aw, I'm sorry.
===
```

```elixir
{:ok, script} = Yarnspinnex.compile_string(source)
cursor = Yarnspinnex.start(script, gold: 10)

case Yarnspinnex.step(script, cursor, context) do
  {:line, %Yarnspinnex.Line{speaker: speaker, text: text}, cursor} -> ...
  {:command, name, args, cursor} -> ...
  {:options, options, cursor} -> {:ok, cursor} = Yarnspinnex.choose(script, cursor, index, context)
  {:done, cursor} -> cursor.vars
end
```

`start/2` enters the `Start` node, or the first node if there is none; `enter/3` enters any node by title.

## Syntax

```yarn
Sally: Your score is {$score}. #line:0a1b2c #shout
<<set $score += 5>>
<<declare $score = 0 as number>>
<<if $score > 10>>
    Sally: Impressive!
<<elseif $score > 0>>
    Sally: Not bad.
<<else>>
    Sally: Ouch.
<<endif>>
-> Buy a pie <<if $gold >= 10>>
    <<spend_gold 10>>
-> Leave
<<jump NextScene>>
[[NextScene]]
[[Say goodbye|NextScene]]
<<stop>>
```

- Speaker: everything before the first `: `. Write `\:` for a literal colon that does not start a speaker.
- `#line:` tag: becomes `id` on the `Line` or `Option`, the usual localization key. Markup such as `[b]` passes through untouched.
- Comments: `//` starts one, except inside quotes.
- Assignment: `<<set>>` accepts `=` or `to`, plus `+= -= *= /= %=`. An `as type` annotation is accepted but not enforced.
- Option conditions: a trailing `<<if>>` sets `enabled?` but keeps the option in the list.
- Option bodies: nested by indentation, after which the dialogue continues below the option group.
- Jumps: a jump never returns, because there is no call stack. Targets must be literal node names, and titles must be valid jump targets (letters, digits, underscores).
- Commands: any other `<<...>>` is a command. Each argument is a bare number (a number), a quoted string, `{expr}` (evaluated), or any other bare word (passed as text, never evaluated). A bare `$name` is a compile error; write `{$name}`.
- Padding: `<< set $x to 1 >>` parses here, but the reference compiler may reject it.

Expressions:

- Operators: `+ - * / %`, `== != < > <= >=` (also `is eq neq lt gt lte gte`), and `and or not xor` (also `&& || ! ^`). `+` also joins strings.
- Built-in functions: `random random_range dice round round_places floor ceil inc dec int decimal string number bool`.
- Number rendering: `{10 / 2}` renders `5` and `{5 / 2}` renders `2.5`.
- Types: ordering comparisons need numbers. Conditions must be `true`, `false`, or `nil` (an unset variable counts as false), so `<<if $count>>` with a number raises; write `$count > 0` or `bool($count)`.

## Variables, context, functions, commands

- Variables: the dialogue's own memory, in `cursor.vars`. Written by `<<set>>` and persisted with the cursor; keep them scalar.
- Context: live host state, passed to every `step/3` and `choose/4`. The script can read it but never write it, and it is never persisted. Context wins when a name is in both.
- Functions: host-declared reads over context, which can take arguments.
- Commands: every write or effect. The host applies them through its own domain code.

`$player` in a script is `player` in Elixir. Vars and context may be keyword lists or maps with atom or string keys. Nested values must be maps, and lookup tries the string key first, then the atom key.

Compile options:

```elixir
Yarnspinnex.compile_string(source,
  functions: MyGame.DialogueFunctions,
  context: [:player, :time_of_day],
  variables: [:met_baker],
  strict: true
)
```

- `:functions`: a `Yarnspinnex.HostFunctions` module. Every call is checked against `declared/0` by name and arity.
- `:context`: names the host owns. Assigning to one of them is a compile error.
- `:variables`: names that arrive in `vars` from outside this script.
- `:strict`: every `$name` that is read must be set or declared in the script, or listed in `:context` or `:variables`. This catches misspellings at compile time.

```elixir
defmodule MyGame.DialogueFunctions do
  @behaviour Yarnspinnex.HostFunctions

  @impl true
  def declared, do: [{"gold", 0}, {"visited", 1}]

  @impl true
  def call("gold", [], context), do: context.player.gold
  def call("visited", [node], context), do: MyGame.Dialogue.visited?(context.player, node)
end
```

`call/3` gets the context exactly as passed to `step/3`.

### Projections

Scripts read scalars, plain maps of scalars, or a `Yarnspinnex.Projection`. Reading a field on a struct, comparing a non-scalar, or rendering one in a line raises, so a domain object passed by mistake fails loudly instead of comparing false. Put anything that needs an argument or a lookup in a host function.

```elixir
context =
  Yarnspinnex.Projection.new(%{
    player: Yarnspinnex.Projection.new(%{class: "mage", level: 5}, source: player),
    time_of_day: "night"
  })
```

The script sees `fields`, while host functions also see `source`. Fields whose names start with `_` are unreadable, which covers `__struct__` and `__meta__`. An unknown field reads as `nil`, and fields are read-only.

## Errors

- `Yarnspinnex.CompileError`, returned by `compile_string/2`: malformed directives, duplicate or invalid titles, unknown jump targets, unknown functions or wrong arity, writes to context names, and (when strict) unknown variables.
- `Yarnspinnex.RuntimeError`, raised by `step/3` and `choose/4`: type errors, division by zero, host function failures, a cursor that does not fit the script, and jump loops that never produce an event.
- `ArgumentError`, raised for caller mistakes: bad options, a module that does not implement `HostFunctions`, a struct passed as vars or context.

The two Yarnspinnex errors carry `node` and `line`, and their message reads like `line 12 in node "Baker": cannot apply > to nil and 5`.

## Persisting

Usually you only need to persist `cursor.vars` and start each conversation at whichever node fits, branching on state:

```yarn
title: Baker
---
<<if visited("Baker_Intro")>>
    <<jump Baker_Waiting>>
<<else>>
    <<jump Baker_Intro>>
<<endif>>
===
```

To resume mid-conversation across requests, store the cursor itself:

```elixir
save!(id, :erlang.term_to_binary(cursor))

cursor = :erlang.binary_to_term(load!(id), [:safe])

with :ok <- Yarnspinnex.check_cursor(script, cursor),
     {:ok, cursor} <- Yarnspinnex.choose(script, cursor, index, context) do
  Yarnspinnex.step(script, cursor, context)
end
```

- Nothing is replayed: each statement runs once, however many requests the conversation spans.
- Bad answers: `choose/4` returns `{:error, :invalid_option}` or `{:error, :option_disabled}`, and nothing runs.
- Fingerprints: a cursor carries its node's fingerprint, and changing that node makes `check_cursor/2` return `{:error, :stale_script}`. Edits to other nodes, comments, and blank lines leave it valid.

## Diagrams

`Yarnspinnex.Mermaid.node_graph/1` draws nodes and jumps, and `flowchart/2` draws every statement. Pass `nodes: [...]` to draw only some nodes.

```elixir
File.write!("dialogue.mmd", Yarnspinnex.Mermaid.flowchart(script))
```

## Not supported

- Statements: `<<detour>>`, `<<return>>`, `<<once>>`.
- Yarn Spinner 3 features: enums, smart variables, node groups.
- Computed jumps: `<<jump $target>>` is a compile error.
- Visit tracking: `visited()` and `visited_count()` are not built in; provide them as host functions.
- Markup: passed through, not parsed.
- Field writes: `<<set $player.gold = 20>>` is invalid; emit a command instead.
