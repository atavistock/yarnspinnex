defmodule Yarnspinnex.ParserTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Analysis
  alias Yarnspinnex.CompileError
  alias Yarnspinnex.Parser

  # The statements of a one-node script, without source lines.
  defp parse_body!(body) do
    {:ok, [node]} = Parser.parse("title: Start\n---\n#{body}\n===\n")
    Analysis.strip_lines(node.body)
  end

  defp parse_error(body) do
    {:error, %CompileError{} = error} = Parser.parse("title: Start\n---\n#{body}\n===\n")
    error
  end

  test "splits nodes, keeps headers, and records where each node starts" do
    source =
      "\uFEFFtitle: Start\ntags: intro\n---\nSally: Hi.\n===\n\ntitle: Next\n---\nSally: Bye.\n===\n"

    assert {:ok, [first, second]} = Parser.parse(source)
    assert %{title: "Start", line: 1, headers: %{"title" => "Start", "tags" => "intro"}} = first
    assert %{title: "Next", line: 7} = second
  end

  test "node structure errors are reported at the node's first line" do
    assert {:error, %CompileError{line: 1, description: "node missing --- separator"}} =
             Parser.parse("title: Start\nSally: Hi.\n===\n")

    assert {:error, %CompileError{line: 2, description: "node missing closing === marker"}} =
             Parser.parse("\ntitle: Start\n---\nSally: Hi.\n")

    assert {:error, %CompileError{line: 1, description: "node missing title header"}} =
             Parser.parse("tags: intro\n---\nSally: Hi.\n===\n")
  end

  test "every statement and option carries its source line" do
    {:ok, [node]} =
      Parser.parse("""
      title: Start
      ---
      N: one
      <<if true>>
          N: two
      <<endif>>
      -> A
          <<set $x = 1>>
      -> B
      ===
      """)

    assert node.body == [
             {:line, "N", [text: "one"], [], 3},
             {:if, [{true, [{:line, "N", [text: "two"], [], 5}]}], [], 4},
             {:options,
              [
                {:option, [text: "A"], nil, [{:set, "x", 1, 8}], [], 7},
                {:option, [text: "B"], nil, [], [], 9}
              ], 7}
           ]
  end

  test "options group by adjacency and nest by indentation, spaces or tabs" do
    assert parse_body!("-> A\n\tN: a\n-> B\n    N: b\nN: x\n-> C") == [
             {:options,
              [
                {:option, [text: "A"], nil, [{:line, "N", [text: "a"], []}], []},
                {:option, [text: "B"], nil, [{:line, "N", [text: "b"], []}], []}
              ]},
             {:line, "N", [text: "x"], []},
             {:options, [{:option, [text: "C"], nil, [], []}]}
           ]
  end

  test "the speaker is everything before the first colon-space, unless the colon is escaped" do
    for {source, speaker, text} <- [
          {"Jos\u00E9: Hola.", "Jos\u00E9", "Hola."},
          {"Dr. Who: Hello.", "Dr. Who", "Hello."},
          {"Guard #2: Halt.", "Guard #2", "Halt."},
          {"Wait, what: really?", "Wait, what", "really?"},
          {"Sally: The time is 5:30", "Sally", "The time is 5:30"},
          {"Wait\\: what: really?", nil, "Wait: what: really?"},
          {"Visit http://example.com", nil, "Visit http:"},
          {"Score:10", nil, "Score:10"}
        ] do
      assert parse_body!(source) == [{:line, speaker, [text: text], []}]
    end

    assert parse_body!("-> Wait\\: what") ==
             [{:options, [{:option, [text: "Wait: what"], nil, [], []}]}]
  end

  test "comments are stripped outside quotes and #tags are split off the end" do
    assert parse_body!("Sally: Hi. #line:abc #happy // note\n// whole line\n<<say \"a // b\">>") ==
             [
               {:line, "Sally", [text: "Hi."], ["line:abc", "happy"]},
               {:command, "say", ["a // b"]}
             ]

    assert parse_body!("-> Go #line:def\n-> Stay <<if true>> #line:ghi") ==
             [
               {:options,
                [
                  {:option, [text: "Go"], nil, [], ["line:def"]},
                  {:option, [text: "Stay"], true, [], ["line:ghi"]}
                ]}
             ]
  end

  test "directives accept padding inside their markers" do
    assert parse_body!(
             "<< set $x to 1 >>\n<< if $x gt 0 >>\n<< jump Start >>\n<< else >>\n<< stop >>\n<< endif >>"
           ) ==
             [
               {:set, "x", 1},
               {:if, [{{:binop, :>, {:var, "x"}, 0}, [{:jump, "Start"}]}], [:stop]}
             ]

    assert parse_body!("[[ Go there | Start ]]") ==
             [{:options, [{:option, [text: "Go there"], nil, [{:jump, "Start"}], []}]}]
  end

  test "assignment forms: =, to, and the compound operators" do
    assert parse_body!(
             "<<set $x = -5>>\n<<set $x to 2>>\n<<set $gold += 10>>\n<<set $gold %= 3>>"
           ) ==
             [
               {:set, "x", {:neg, 5}},
               {:set, "x", 2},
               {:set, "gold", {:binop, :+, {:var, "gold"}, 10}},
               {:set, "gold", {:binop, :%, {:var, "gold"}, 3}}
             ]

    assert parse_body!("<<declare $x = 5 as number>>") == [{:declare, "x", 5}]
  end

  test "operators may be written as words, and xor binds loosest" do
    assert parse_body!("N: {$a is 1 and $b neq 2} {$a lt 1 or $a gte 1 xor true ^ false}") ==
             [
               {:line, "N",
                [
                  expr:
                    {:binop, :and, {:binop, :==, {:var, "a"}, 1}, {:binop, :!=, {:var, "b"}, 2}},
                  text: " ",
                  expr:
                    {:binop, :xor,
                     {:binop, :xor,
                      {:binop, :or, {:binop, :<, {:var, "a"}, 1}, {:binop, :>=, {:var, "a"}, 1}},
                      true}, false}
                ], []}
             ]
  end

  test "command arguments keep quoted strings and {expressions} whole" do
    assert parse_body!("<<give sword 2 \"two words\" {$gold + 1} {\"a b\"}>>") ==
             [
               {:command, "give",
                ["sword", 2, "two words", {:binop, :+, {:var, "gold"}, 1}, "a b"]}
             ]

    assert %CompileError{line: 3, description: "unterminated { in command"} =
             parse_error("<<give {$gold>>")

    assert %CompileError{line: 3, description: "unterminated string in command"} =
             parse_error("<<say \"oops>>")

    assert %CompileError{line: 3, description: "unknown identifier oops" <> _} =
             parse_error("<<give {oops}>>")
  end

  test "malformed directives are errors, never custom commands" do
    for text <- [
          "<<set $x>>",
          "<<set $x = >>",
          "<<declare $x += 1>>",
          "<<jump>>",
          "<<jump $target>>",
          "<<jump Two Words>>",
          "<<if>>",
          "<<elseif>>",
          "<<stop now>>"
        ] do
      assert %CompileError{line: 3, node: "Start", description: "malformed <<" <> _ = description} =
               parse_error(text)

      assert String.ends_with?(description, text)
    end

    assert %CompileError{description: "malformed statement: <<if $x>"} = parse_error("<<if $x>")

    assert %CompileError{description: "malformed shorthand jump: [[Some Node]]"} =
             parse_error("[[Some Node]]")

    assert %CompileError{description: "unknown identifier tru" <> _} =
             parse_error("<<set $x = tru>>")
  end

  test "expression errors name the line, including inside nested branches" do
    assert %CompileError{line: 3, description: "expected a variable name after $"} =
             parse_error("N: {$ + 1}")

    assert %CompileError{line: 3, description: "unterminated string in line"} =
             parse_error("N: {\"oops}")

    assert %CompileError{line: 3, description: "unknown or unsupported yarn function: nope"} =
             parse_error("N: {nope(1)}")

    assert %CompileError{line: 5, description: "unexpected token(s) in expression: []"} =
             parse_error("<<if true>>\n    N: fine\n<<elseif $x +>>\n    N: bad\n<<endif>>")
  end

  test "block structure errors name the line and render with node and line" do
    assert %CompileError{line: 4, description: "expected <<endif>>, reached end of node"} =
             parse_error("N: a\n<<if true>>\n    N: b")

    error = parse_error("<<else>>")
    assert %CompileError{line: 3, node: "Start"} = error

    assert Exception.message(error) ==
             "line 3 in node \"Start\": unexpected or unmatched control statement: <<else>>"
  end

  test "the default options accept every built-in function" do
    assert parse_body!("N: {string(dice(6))}") ==
             [{:line, "N", [expr: {:call, "string", [{:call, "dice", [6]}]}], []}]
  end
end
