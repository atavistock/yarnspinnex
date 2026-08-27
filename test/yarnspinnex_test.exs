defmodule YarnspinnexTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Cursor
  alias Yarnspinnex.Line
  alias Yarnspinnex.Option
  alias Yarnspinnex.TestPlayer
  alias Yarnspinnex.TestRuntime

  # Compiles a script whose Start node has `body`, plus any `extra` nodes.
  defp compile!(body, extra \\ "") do
    {:ok, script} = Yarnspinnex.compile_string("title: Start\n---\n#{body}\n===\n#{extra}")
    script
  end

  # -- running a script ----------------------------------------------------------

  test "lines, interpolation, set, if/elseif/else, and jumps" do
    script =
      compile!(
        """
        <<set $mood = 5>>
        Sally: Hi there.
        <<if $mood > 10>>
            Sally: Ecstatic!
        <<elseif $mood > 3>>
            Sally: You seem happy!
        <<else>>
            Sally: Rough day?
        <<endif>>
        Sally: Your mood is {$mood}, {"Score: " + string($mood * 2)}.
        <<jump Next>>
        Sally: Never said.
        """,
        "title: Next\n---\nSally: On to the next node.\n===\n"
      )

    final = TestRuntime.run(script)

    assert final.log == [
             {:line, "Sally", "Hi there."},
             {:line, "Sally", "You seem happy!"},
             {:line, "Sally", "Your mood is 5, Score: 10."},
             {:line, "Sally", "On to the next node."}
           ]

    assert final.vars == %{"mood" => 5}
    assert final.cursor.node == "Next"
  end

  test "options expose enabled?, run the chosen body, then continue after the group" do
    script =
      compile!("""
      <<set $unlocked = false>>
      -> Locked door <<if $unlocked>>
          Sally: The door creaks open.
      -> Go home
          -> Slowly
              Sally: Dawdling.
          -> Quickly
              Sally: Hurrying.
          Sally: Home at last.
      Sally: The end.
      """)

    choose = fn options -> Enum.find(options, &(&1.text in ["Go home", "Quickly"])) end

    assert TestRuntime.run(script, choose: choose).log == [
             {:options, [{"Locked door", false}, {"Go home", true}]},
             {:options, [{"Slowly", true}, {"Quickly", true}]},
             {:line, "Sally", "Hurrying."},
             {:line, "Sally", "Home at last."},
             {:line, "Sally", "The end."}
           ]
  end

  test "a jump or stop inside an option body ends the node without running what follows" do
    jumping =
      compile!(
        "-> A\n    <<jump Other>>\nSally: After.",
        "title: Other\n---\nSally: Elsewhere.\n===\n"
      )

    assert TestRuntime.run(jumping).log == [
             {:options, [{"A", true}]},
             {:line, "Sally", "Elsewhere."}
           ]

    stopping = compile!("-> A\n    <<stop>>\nSally: After.")
    assert TestRuntime.run(stopping).log == [{:options, [{"A", true}]}]
  end

  test "shorthand jumps: [[Node]] jumps, [[Label|Node]] is a single-option group" do
    script =
      compile!(
        "[[Next]]",
        "title: Next\n---\n[[ Go on | Last ]]\n===\ntitle: Last\n---\nSally: Arrived.\n===\n"
      )

    assert TestRuntime.run(script).log == [
             {:options, [{"Go on", true}]},
             {:line, "Sally", "Arrived."}
           ]
  end

  test "<<declare>> sets a default only when the variable is unset" do
    script =
      compile!("""
      <<declare $mood = 1 as number>>
      <<set $mood = 5>>
      <<declare $mood = 1>>
      <<declare $name = "Pyramid" as string>>
      Sally: {$name} is at {$mood}.
      """)

    final = TestRuntime.run(script)
    assert final.vars == %{"mood" => 5, "name" => "Pyramid"}
    assert final.log == [{:line, "Sally", "Pyramid is at 5."}]
  end

  test "commands come back with their arguments evaluated" do
    script =
      compile!("<<shake 0.5 \"big\">>\n<<give {$gold + 1} sword \"two words\" {string($gold)}>>")

    assert TestRuntime.run(script, vars: [gold: 5]).log == [
             {:command, "shake", [0.5, "big"]},
             {:command, "give", [6, "sword", "two words", "5"]}
           ]
  end

  test "compound assignment and word operators run like their symbol forms" do
    script =
      compile!("""
      <<set $gold = 10>>
      <<set $gold += 5>>
      <<set $gold -= 3>>
      <<set $gold *= 2>>
      N: {$gold} {$gold is 24} {$gold gt 100} {true xor $gold gte 24} {5.5 % 2} {10 / 2}
      """)

    final = TestRuntime.run(script)
    assert final.vars["gold"] == 24
    assert final.log == [{:line, "N", "24 true false false 1.5 5"}]
  end

  test "a condition must be true or false; an unset variable counts as false" do
    fine = compile!("<<if $unset>>\nN: no\n<<elseif not $unset and true>>\nN: yes\n<<endif>>")
    assert TestRuntime.run(fine).log == [{:line, "N", "yes"}]

    for body <- [
          "<<if $count>>\nN: x\n<<endif>>",
          "N: {$count and true}",
          "-> A <<if $count>>\n    N: x"
        ] do
      error =
        assert_raise(Yarnspinnex.RuntimeError, fn ->
          TestRuntime.run(compile!(body), vars: [count: 5])
        end)

      assert Exception.message(error) =~ "expected true or false in a condition, got 5"
    end

    converted = compile!("<<if bool($count) and $count > 0>>\nN: counted\n<<endif>>")
    assert TestRuntime.run(converted, vars: [count: 5]).log == [{:line, "N", "counted"}]
  end

  test "an escaped colon renders as a colon and never makes a speaker" do
    script = compile!("Wait\\: what: really?\nSally: Fine\\: sure.")

    assert TestRuntime.run(script).log == [
             {:line, nil, "Wait: what: really?"},
             {:line, "Sally", "Fine: sure."}
           ]
  end

  test "a domain struct reaching dialogue fails loudly at the field, the comparison, and the text" do
    player = %TestPlayer{strength: 15}

    for {body, context, message} <- [
          {"<<if $player.strength > 12>>\nN: x\n<<endif>>", [player: player],
           ~r/cannot read field "strength" on a .*TestPlayer struct/},
          {"<<if $player.class == \"mage\">>\nN: x\n<<endif>>", [player: %{class: player}],
           ~r/cannot compare a .*TestPlayer struct with ==/},
          {"N: {$player.class}", [player: %{class: player}],
           ~r/cannot render a .*TestPlayer struct as dialogue text/}
        ] do
      assert_raise Yarnspinnex.RuntimeError, message, fn ->
        TestRuntime.run(compile!(body), context: context)
      end
    end
  end

  # -- the stepping API -----------------------------------------------------------

  test "step returns one event at a time and choose answers an option group" do
    script =
      compile!("""
      Sally: Pick one. #line:abc #shout
      -> Red #line:def
          Sally: Red it is.
      -> Blue <<if false>>
          Sally: Unreachable.
      <<fade 1>>
      """)

    cursor = Yarnspinnex.start(script)
    assert %Cursor{node: "Start", path: [], index: 0, vars: %{}, script: fingerprint} = cursor
    assert fingerprint == script.fingerprint

    assert {:line,
            %Line{speaker: "Sally", text: "Pick one.", tags: ["line:abc", "shout"], id: "abc"},
            cursor} = Yarnspinnex.step(script, cursor)

    assert {:options, options, cursor} = Yarnspinnex.step(script, cursor)

    assert options == [
             %Option{index: 0, text: "Red", enabled?: true, tags: ["line:def"], id: "def"},
             %Option{index: 1, text: "Blue", enabled?: false}
           ]

    assert {:options, ^options, ^cursor} = Yarnspinnex.step(script, cursor)

    assert {:error, :invalid_option} = Yarnspinnex.choose(script, cursor, 2)
    assert {:error, :option_disabled} = Yarnspinnex.choose(script, cursor, 1)
    assert {:ok, cursor} = Yarnspinnex.choose(script, cursor, 0)

    assert {:line, %Line{text: "Red it is.", tags: [], id: nil}, cursor} =
             Yarnspinnex.step(script, cursor)

    assert {:command, "fade", [1], cursor} = Yarnspinnex.step(script, cursor)
    assert {:error, :no_options} = Yarnspinnex.choose(script, cursor, 0)
    assert {:done, cursor} = Yarnspinnex.step(script, cursor)
    assert {:done, ^cursor} = Yarnspinnex.step(script, cursor)
  end

  test "enter/3 starts at a named node and rejects unknown titles" do
    script = compile!("Sally: Start.", "title: Other\n---\nSally: Other.\n===\n")

    assert {:ok, cursor} = Yarnspinnex.enter(script, "Other", x: 1)

    assert {:line, %Line{text: "Other."}, %Cursor{vars: %{"x" => 1}}} =
             Yarnspinnex.step(script, cursor)

    assert {:error, :unknown_node} = Yarnspinnex.enter(script, "Nowhere")
  end

  test "a cursor survives serialization and resumes exactly where it paused" do
    script =
      compile!(
        "<<set $count = $count + 1>>\nSally: Pick one.\n-> Leave\n    <<jump Bye>>\n-> Stay\n    Sally: Staying.\nSally: After.",
        "title: Bye\n---\nSally: Goodbye.\n===\n"
      )

    cursor = Yarnspinnex.start(script, count: 0)
    assert {:line, _, cursor} = Yarnspinnex.step(script, cursor)
    assert {:options, _, cursor} = Yarnspinnex.step(script, cursor)

    restored = cursor |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert restored == cursor
    assert restored.vars == %{"count" => 1}

    assert {:ok, stayed} = Yarnspinnex.choose(script, restored, 1)
    assert {:line, %Line{text: "Staying."}, stayed} = Yarnspinnex.step(script, stayed)
    assert {:line, %Line{text: "After."}, stayed} = Yarnspinnex.step(script, stayed)

    assert {:done, %Cursor{node: "Start", vars: %{"count" => 1}}} =
             Yarnspinnex.step(script, stayed)

    assert {:ok, left} = Yarnspinnex.choose(script, restored, 0)
    assert {:line, %Line{text: "Goodbye."}, left} = Yarnspinnex.step(script, left)
    assert {:done, %Cursor{node: "Bye"}} = Yarnspinnex.step(script, left)
  end

  test "jump loops inside one step run in constant stack space" do
    script =
      compile!(
        "<<set $n = $n + 1>>\n<<if $n < 200000>>\n    <<jump Start>>\n<<endif>>\nSally: Done."
      )

    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: 100_000, kill: true, error_logger: false})
        TestRuntime.run(script, vars: [n: 0]).vars["n"]
      end)

    assert Task.await(task, 30_000) == 200_000
  end

  # -- cursor integrity and runtime errors --------------------------------------------

  test "a cursor from another version of the script is refused; comment edits do not count" do
    body = "N: one\n-> A\n    N: chose A\n-> B\n    N: chose B"
    v1 = compile!(body)
    cursor = Yarnspinnex.start(v1)
    {:line, _, cursor} = Yarnspinnex.step(v1, cursor)
    {:options, _, cursor} = Yarnspinnex.step(v1, cursor)

    assert Yarnspinnex.check_cursor(v1, cursor) == :ok
    assert Yarnspinnex.check_cursor(compile!("// a comment\n\n" <> body), cursor) == :ok

    v2 = compile!("N: NEW\n" <> body)
    assert Yarnspinnex.check_cursor(v2, cursor) == {:error, :stale_script}

    assert_raise Yarnspinnex.RuntimeError, ~r/different version of the script/, fn ->
      Yarnspinnex.step(v2, cursor)
    end
  end

  test "a corrupted cursor is refused rather than wrapping around" do
    script = compile!("N: first\nN: second")
    cursor = Yarnspinnex.start(script)

    assert Yarnspinnex.check_cursor(script, %{cursor | index: 2}) == :ok

    for broken <- [
          %{cursor | index: -1},
          %{cursor | index: 99},
          %{cursor | path: [{-1, {:if, 0}}]},
          %{cursor | path: [{0, {:option, 0}}]}
        ] do
      assert Yarnspinnex.check_cursor(script, broken) == {:error, :invalid_position}
      assert_raise Yarnspinnex.RuntimeError, fn -> Yarnspinnex.step(script, broken) end
    end

    assert Yarnspinnex.check_cursor(script, %{cursor | node: "Nowhere"}) ==
             {:error, :unknown_node}
  end

  test "a script that jumps in a circle without saying anything raises instead of hanging" do
    script = compile!("<<set $n = $n + 1>>\n<<jump Start>>")

    assert_raise Yarnspinnex.RuntimeError, ~r/is there a jump loop\?/, fn ->
      Yarnspinnex.step(script, Yarnspinnex.start(script, n: 0))
    end
  end

  test "a runtime error names the node and line it happened on" do
    script =
      compile!(
        "N: fine\n<<jump Other>>",
        "title: Other\n---\nN: also fine\n-> A\n    <<if $unset > 5>>\n    N: x\n    <<endif>>\n===\n"
      )

    error = assert_raise(Yarnspinnex.RuntimeError, fn -> TestRuntime.run(script) end)

    assert %Yarnspinnex.RuntimeError{node: "Other", line: 10, path: [{1, {:option, 0}}], index: 0} =
             error

    assert Exception.message(error) == "line 10 in node \"Other\": cannot apply > to nil and 5"
  end
end
