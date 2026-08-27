# Yarnspinnex

Yarnspinnex compiles [Yarn Spinner](https://www.yarnspinner.dev/) dialogue into a `Yarnspinnex.Script` - plain data, safe to cache - and runs it one event at a time against a `Yarnspinnex.Cursor` that your application owns, persists, and hands back. Nothing blocks and nothing runs in a process of its own: the dialogue advances exactly as fast as whoever calls `step/3`.

## Installation

Add it to your dependencies in `mix.exs`, from Hex once published or straight from GitHub until then:

```elixir
def deps do
  [
    {:yarnspinnex, github: "atavistock/yarnspinnex"}
  ]
end
```

There are no runtime dependencies.

## Quick start

A Yarn script is one or more nodes, each a `title:` header, a `---` separator, a body, and a closing `===`.

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

Compile it, take a cursor at the start node, and step until the dialogue is done. Every step returns the next line, command, or option group together with the cursor to continue from, and an option group is answered with `choose/4`:

```elixir
defmodule Player do
  def play(script, cursor, context) do
    case Yarnspinnex.step(script, cursor, context) do
      {:line, line, cursor} ->
        IO.puts("#{line.speaker}: #{line.text}")
        play(script, cursor, context)

      {:command, name, args, cursor} ->
        IO.puts("<<#{name} #{inspect(args)}>>")
        play(script, cursor, context)

      {:options, options, cursor} ->
        Enum.each(options, &IO.puts("#{&1.index}. #{&1.text}"))
        chosen = Enum.find(options, & &1.enabled?)
        {:ok, cursor} = Yarnspinnex.choose(script, cursor, chosen.index, context)
        play(script, cursor, context)

      {:done, cursor} ->
        cursor.vars
    end
  end
end

{:ok, script} = Yarnspinnex.compile_string(source)
Player.play(script, Yarnspinnex.start(script, gold: 10), %{})
```

`Yarnspinnex.start/2` positions a cursor at the `Start` node (or the first node) holding the given variables; `Yarnspinnex.enter/3` does the same for any node by title.

## Syntax

Lines have an optional speaker, `{...}` interpolation, and trailing `#tags`:

```yarn
Sally: Your score is {$score}. #line:0a1b2c #shout
Just narration, no speaker.
```

The first comes back as `%Yarnspinnex.Line{speaker: "Sally", text: "Your score is 5.", tags: ["line:0a1b2c", "shout"], id: "0a1b2c"}`. `id` is the value of the `#line:` tag, which is what a localization table is keyed by; options carry `tags` and `id` the same way. Markup such as `[b]...[/b]` passes through untouched in `text` for the host to render.

Everything before the first colon-space on a line is the speaker, whatever characters it holds (`Dr. Who: Hello`, `Guard #2: Halt`), as in Yarn Spinner. Escape the colon as `\:` to keep a line from being read that way: `Wait\: what?` renders as `Wait: what?` with no speaker. `//` starts a comment, outside of quotes.

Variables are set or declared, with `+= -= *= /= %=` updating in place and an optional type annotation that is accepted but not enforced:

```yarn
<<set $score = 10>>
<<set $score to 10>>
<<set $score += 5>>
<<declare $score = 0 as number>>
```

Conditionals chain with `<<elseif>>`:

```yarn
<<if $score > 10>>
    Sally: Impressive!
<<elseif $score > 0>>
    Sally: Not bad.
<<else>>
    Sally: Ouch.
<<endif>>
```

Options carry an optional trailing `<<if ...>>` that gates `enabled?` without removing the option from the list. Option bodies are nested by indentation, spaces or tabs, and whatever follows the group runs once the chosen option's body finishes:

```yarn
-> Buy a pie <<if $gold >= 10>>
    <<spend_gold 10>>
    Baker: Enjoy!
-> Leave
    Baker: Suit yourself.
Baker: Come back soon.
```

Jumps take a literal node name, in either form. A jump never returns to the node that jumped - there is no call stack - so dialogue that must come back to its caller is written as its own node with an explicit jump back:

```yarn
<<jump NextScene>>
[[NextScene]]
[[Say goodbye|NextScene]]
```

`<<stop>>` ends the dialogue immediately. Anything else inside `<<...>>` is a custom command, returned from `step/3` as `{:command, name, args, cursor}` with its arguments evaluated: a bare word is passed as a string, a quoted string may contain spaces, and `{...}` holds any expression:

```yarn
<<stop>>
<<shake 0.5 "big">>
<<give sword {$gold + 1}>>
```

Padding inside the markers is accepted, so `<< set $gold to 10 >>` parses as well as `<<set $gold to 10>>`. That is a superset of what the reference Yarn Spinner compiler is documented to accept; keep to the tight form if your scripts also need to build there.

Expressions support arithmetic (`+ - * / %`), comparison (`== != < > <= >=`, or in words `is eq neq lt gt lte gte`), boolean logic (`and or not xor`, or `&& || ! ^`), string concatenation with `+`, parenthesized grouping, and the built-in functions `random`, `random_range`, `dice`, `round`, `round_places`, `floor`, `ceil`, `inc`, `dec`, `int`, `decimal`, `string`, `number`, `bool`. Whole numbers print without a decimal point (`{10 / 2}` is `5`) and others as written (`{5 / 2}` is `2.5`).

Types are checked where they matter. The ordering comparisons require numbers on both sides. A condition - an `<<if>>`, an option's `<<if>>`, or an operand of `and`, `or`, `not`, `xor` - must be `true` or `false`: an unset variable reads as `nil` and counts as false, but `<<if $count>>` with a number is an error, so write `$count > 0` or `bool($count)`.

## Variables, context, functions, and commands

A script reads and writes through four channels. Keeping them separate is what stops dialogue content - which lives in a database, where the compiler cannot see it and a rename cannot be automated - from becoming coupled to your domain model.

**Variables** are the dialogue's own memory: `asked_about_wife`, `insulted_baker`, `pies_bought`. They live in `cursor.vars`, are written by `<<set>>`, and persist with the cursor. Keep them to scalars so they survive a trip through `jsonb`.

**Context** is live host state the script may read but never write: the player projection, the current location, the time of day. It is passed to each `step/3` and `choose/4` call and never persisted. It may hold anything your host functions need, structs and all, but whatever the script reads by name must be a scalar or a projection (see below).

**Functions** are the declared read vocabulary over context: `gold()`, `party_has_class("mage")`. They take arguments, which dotted paths cannot, and the list of them is a literal whitelist.

**Commands** are every write and effect: `<<spend_gold 100>>`, `<<complete_quest baker_bread>>`. They come back from `step/3` for the host to apply through its own domain functions, so game rules stay in game code and go through your validations and transactions.

### Names

The sigil is source syntax only: `$player` in a script and `player:` in Elixir are the same name. Pass variables and context as a keyword list, an atom-keyed map, or a string-keyed map, whichever reads better. A name is looked up as a string key first and then as an atom key, at every level, so a map straight out of `jsonb` and a map built in your own code read the same:

```elixir
cursor = Yarnspinnex.start(script, gold: 10, asked_about_wife: false)
Yarnspinnex.step(script, cursor, %{player: player_view, time_of_day: "night"})

cursor.vars["gold"]
```

When a name is in both, context wins - game truth beats stale dialogue memory. Declare the context names at compile time and assigning to one becomes an error rather than a write that silently disappears:

```elixir
Yarnspinnex.compile_string(source, context: [:player, :gold, :time_of_day])
# {:error, %Yarnspinnex.CompileError{}} for a script containing <<set $gold = 5>>
```

### Strict variables

A misspelled variable reads as `nil`, which renders as empty text and counts as false - a bug that only shows up in play. With `strict: true`, every `$name` a script reads must be `<<set>>` or `<<declare>>`d somewhere in it or be a name the host provides, and anything else is a compile error with a line:

```elixir
Yarnspinnex.compile_string(source, strict: true, context: [:player], variables: [:met_baker, :quest_stage])
# line 7 in node "Baker": $playr is never set or declared in the script and is not provided by the host; is it misspelled?
```

`:variables` lists the names that arrive in `vars` from outside this script - persisted from earlier conversations, or set by another script - so they need not be declared in every script that reads them.

### Host functions

Implement `Yarnspinnex.HostFunctions` and pass the module at compile time. `declared/0` validates every call in the script, down to arity, and doubles as the manifest an editor can list for autocomplete:

```elixir
defmodule MyGame.DialogueFunctions do
  @behaviour Yarnspinnex.HostFunctions

  @impl true
  def declared, do: [{"gold", 0}, {"party_has_class", 1}, {"visited", 1}]

  @impl true
  def call("gold", [], context), do: context.player.gold
  def call("party_has_class", [class], context), do: MyGame.Party.has_class?(context.party, class)
  def call("visited", [node], context), do: MyGame.Dialogue.visited?(context.player, node)
end

{:ok, script} = Yarnspinnex.compile_string(source, functions: MyGame.DialogueFunctions)
```

`call/3` receives the context exactly as you passed it to `step/3` - structs, atom keys, and all. Only `$name` lookup normalizes names.

### Projections

Dialogue reads scalars: numbers, strings, booleans, and `nil`. A value the script reads is either one of those, a plain map of them, or a `Yarnspinnex.Projection` - all built by the host:

```elixir
defp project(player) do
  %{class: player.class.name, level: player.level, gold: player.gold}
end

Yarnspinnex.step(script, cursor, player: project(player), time_of_day: "night")
```

```yarn
<<if $player.class == "mage" and $player.level > 3>>
    Baker: A mage, eh?
<<endif>>
```

`Yarnspinnex.Projection` is the same thing with a place to keep what dialogue must not see. `fields` is what a script can read; `source` holds whatever it was projected from, for your own functions and for cache invalidation. It works as one value in the context or as the whole context, so a single cached projection can map out everything a script may read:

```elixir
context =
  Yarnspinnex.Projection.new(%{
    player: Yarnspinnex.Projection.new(%{class: "mage", level: 5}, source: player),
    location: "the bakery",
    time_of_day: "night"
  })

Yarnspinnex.step(script, cursor, context)
```

Host functions receive it whole, `source` included, so `context.player.source.gold` reads the live entity while the script sees only `class` and `level`.

Passing the domain object instead of a projection is refused at the point of use rather than quietly producing the wrong answer: reading a field on a struct raises, comparing a non-scalar with `==` or `!=` raises rather than answering `false`, and rendering a non-scalar in a line raises instead of failing with a protocol error. The reason projections are a rule and not a preference: `$player.class` on a real schema hands you a `%Player.Class{}`, so `$player.class == "mage"` would be silently false while `$player.class.name` worked, and content that walks your object graph lives in a database where no compiler will catch a rename. Anything needing an argument or a lookup belongs in a host function rather than a deeper field path.

Field names beginning with `_` are never readable from a script, so `$player.__struct__` and Ecto's `__meta__` are closed off; on a plain map that leaves the prefix free for host-only values. An unknown field reads as `nil`, the same as an unset variable. Field access is read-only.

## Errors

`compile_string/2` returns `{:error, %Yarnspinnex.CompileError{}}` for anything it can catch before a script runs: malformed directives, duplicate node titles, jumps to nodes that do not exist, calls to undeclared functions or with the wrong arity, assignments to context-owned names, and, with `strict: true`, reads of variables that nothing sets. The error carries the node title and source line where known, and `Exception.message/1` renders it as `line 12 in node "Start": malformed <<set>> statement: <<set $x>>`.

What cannot be caught at compile time - a type error in an expression, a host function that fails, a cursor that does not fit the script, a script that jumps in a circle without ever saying anything - raises `%Yarnspinnex.RuntimeError{}` from `step/3` or `choose/4`, located the same way: `line 12 in node "Baker": cannot apply > to nil and 5`.

Mistakes in the calling code rather than in the script - an unknown option to `compile_string/2`, a `functions:` module that does not implement the behaviour, a struct where a map or keyword list of names was expected - raise `ArgumentError`.

## Persisting a dialogue

Most games need only the variables. Keep the cursor in process state (LiveView assigns, a channel, a per-player GenServer) and persist `cursor.vars` when a conversation ends, or at each pause if an abandoned conversation should keep the `<<set>>`s it made. A later conversation starts fresh at whatever node fits, with everything the player has done already in scope. That is how Yarn Spinner itself works, and it is what makes state-dependent entry easy - here with `visited` provided by the host functions above:

```yarn
title: Baker
---
<<if visited("Baker_Intro") and $quest_baker == "done">>
    <<jump Baker_Reward>>
<<elseif visited("Baker_Intro")>>
    <<jump Baker_Waiting>>
<<else>>
    <<jump Baker_Intro>>
<<endif>>
===
```

If you also need to resume mid-conversation across a process boundary - a stateless HTTP request, a reconnect, a deploy between showing options and receiving the answer - the cursor is plain data with no reference to the script, so it can go in a column:

```elixir
defmodule Session do
  # Steps until the player has to answer or the dialogue ends, collecting what was said on the way.
  def advance(script, cursor, context, said \\ []) do
    case Yarnspinnex.step(script, cursor, context) do
      {:line, line, cursor} -> advance(script, cursor, context, [line | said])
      {:command, name, args, cursor} -> advance(script, cursor, context, [{:command, name, args} | said])
      {:options, options, cursor} -> {:options, Enum.reverse(said), options, cursor}
      {:done, cursor} -> {:done, Enum.reverse(said), cursor}
    end
  end
end
```

Save at the pause; when the player replies, load the cursor, confirm it still fits the script, answer the choice, and advance again:

```elixir
{:options, said, options, cursor} = Session.advance(script, Yarnspinnex.start(script, vars), context)
save!(player_id, :erlang.term_to_binary(cursor))

# ... later, another request ...
cursor = :erlang.binary_to_term(load!(player_id), [:safe])

with :ok <- Yarnspinnex.check_cursor(script, cursor),
     {:ok, cursor} <- Yarnspinnex.choose(script, cursor, chosen_index, context) do
  Session.advance(script, cursor, context)
end
```

`choose/4` returns `{:error, :invalid_option}` or `{:error, :option_disabled}` for an answer that does not fit the group on offer, so a stale or tampered reply is rejected before anything runs. Nothing is replayed: every statement before a pause runs exactly once, however many requests the conversation spans.

A cursor carries the fingerprint of the script it was created from. One stored across a content change is refused - `check_cursor/2` returns `{:error, :stale_script}` and `step/3` raises - rather than silently resuming at a statement that has shifted; restart the node in that case. The fingerprint ignores comments and blank lines, so editing those or recompiling unchanged source keeps every stored cursor valid. `check_cursor/2` also rejects a cursor whose position is corrupt or whose node no longer exists. Variables carry no such constraint.

## Not supported

Detours (`<<detour>>` and `<<return>>`), `<<once>>`, enums, smart variables, and node groups from Yarn Spinner 3 are not implemented. Jump targets must be literal node names, so `<<jump $target>>` is a compile error. `visited()` and `visited_count()` are not built in; provide them as host functions over your own records. Markup inside lines is passed through rather than parsed. Writing to a field (`<<set $player.gold = 20>>`) is not valid; emit a command and apply it through your own domain function.

## Development

```
mix test
mix docs
```

CI runs the format check, a warnings-as-errors compile, and the suite on the Elixir and Erlang versions pinned in `.mise.toml`.
