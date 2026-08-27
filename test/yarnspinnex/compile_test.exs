defmodule Yarnspinnex.CompileTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.CompileError
  alias Yarnspinnex.TestFunctions

  defp compile(source, opts \\ []), do: Yarnspinnex.compile_string(source, opts)

  defp error(source, opts \\ []) do
    {:error, %CompileError{} = error} = compile(source, opts)
    error
  end

  test "an empty script is an error" do
    assert {:error, %CompileError{description: "no nodes to compile"}} = compile("")
  end

  test "duplicate node titles are rejected at the second occurrence" do
    error = error("title: Start\n---\nN: a\n===\ntitle: Start\n---\nN: b\n===\n")
    assert Exception.message(error) == "line 5: duplicate node title: \"Start\""
  end

  test "jumps to unknown nodes are rejected wherever they are nested" do
    error = error("title: Start\n---\nN: a\n<<jump Nowhere>>\n===\n")

    assert Exception.message(error) ==
             "line 4 in node \"Start\": jump to unknown node \"Nowhere\""

    nested = "title: Start\n---\n-> A\n    <<if true>>\n        [[Nowhere]]\n    <<endif>>\n===\n"
    assert %CompileError{line: 5, node: "Start"} = error(nested)
  end

  test "functions are checked by name and arity against the built-ins and the host module" do
    assert %CompileError{line: 3, description: "unknown or unsupported yarn function: length"} =
             error("title: Start\n---\nN: {length(1)}\n===\n")

    assert %CompileError{description: "dice takes 1 argument(s), given 2"} =
             error("title: Start\n---\nN: {dice(1, 2)}\n===\n")

    assert %CompileError{description: "unknown or unsupported yarn function: gold"} =
             error("title: Start\n---\nN: {gold()}\n===\n")

    assert {:ok, _script} =
             compile("title: Start\n---\nN: {gold()}\n===\n", functions: TestFunctions)

    assert %CompileError{description: "party_has_class takes 1 argument(s), given 2"} =
             error("title: Start\n---\nN: {party_has_class(\"a\", 2)}\n===\n",
               functions: TestFunctions
             )
  end

  test "a host module that redeclares a built-in is rejected" do
    defmodule Shadowing do
      @behaviour Yarnspinnex.HostFunctions
      @impl true
      def declared, do: [{"round", 1}]
      @impl true
      def call(_name, _args, _context), do: nil
    end

    assert %CompileError{description: "round is a built-in function and cannot be redeclared"} =
             error("title: Start\n---\nN: hi\n===\n", functions: Shadowing)
  end

  test "a bad functions module or an unknown option is a caller error" do
    assert_raise ArgumentError, ~r/does not implement Yarnspinnex.HostFunctions/, fn ->
      compile("title: Start\n---\nN: hi\n===\n", functions: Enum)
    end

    assert_raise ArgumentError, ~r/unknown keys \[:function\]/, fn ->
      compile("title: Start\n---\nN: hi\n===\n", function: TestFunctions)
    end
  end

  test "assigning to a declared context name is an error" do
    opts = [context: [:gold]]

    assert %CompileError{
             line: 3,
             description: "cannot assign to $gold: the host context owns that name"
           } =
             error("title: Start\n---\n<<set $gold = 5>>\n===\n", opts)

    assert %CompileError{description: "cannot assign to $gold" <> _} =
             error("title: Start\n---\n<<declare $gold = 5>>\n===\n", opts)

    assert {:ok, _script} = compile("title: Start\n---\n<<set $mood = 5>>\n===\n", opts)
  end

  test "strict mode rejects a variable that nothing sets, declares, or provides" do
    source =
      "title: Start\n---\n<<set $gold = 5>>\nN: {$gold} {$playr}\n-> Go <<if $missing>>\n===\n"

    assert {:ok, _script} = compile(source)

    error = error(source, strict: true)

    assert Exception.message(error) ==
             "line 4 in node \"Start\": $playr is never set or declared in the script and is " <>
               "not provided by the host; is it misspelled?"

    assert %CompileError{line: 5, description: "$missing" <> _} =
             error(source, strict: true, variables: [:playr])

    assert {:ok, _script} =
             compile(source, strict: true, variables: [:playr], context: [:missing])

    declared =
      "title: Start\n---\n<<declare $seen = false>>\n===\ntitle: Next\n---\nN: {$seen}\n===\n"

    assert {:ok, _script} = compile(declared, strict: true)
  end
end
