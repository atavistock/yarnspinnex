defmodule Yarnspinnex.ContextTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Projection
  alias Yarnspinnex.TestFunctions
  alias Yarnspinnex.TestPlayer
  alias Yarnspinnex.TestRuntime

  defp compile!(body, opts \\ []) do
    {:ok, script} = Yarnspinnex.compile_string("title: Start\n---\n#{body}\n===\n", opts)
    script
  end

  test "vars are keyed by bare name whether given as a keyword list, atom map, or string map" do
    script = compile!("<<set $mood = $mood + 1>>\nN: {$mood} for {$name}.")

    for vars <- [
          [mood: 4, name: "Sally"],
          %{mood: 4, name: "Sally"},
          %{"mood" => 4, "name" => "Sally"}
        ] do
      final = TestRuntime.run(script, vars: vars)
      assert final.log == [{:line, "N", "5 for Sally."}]
      assert final.vars == %{"mood" => 5, "name" => "Sally"}
    end
  end

  test "a struct is rejected as vars and as the whole context" do
    script = compile!("N: hi")

    assert_raise ArgumentError, ~r/vars must be a map or keyword list.*TestPlayer struct/, fn ->
      Yarnspinnex.start(script, %TestPlayer{})
    end

    assert_raise ArgumentError,
                 ~r/context must be a map, a keyword list, or a Yarnspinnex.Projection/,
                 fn ->
                   Yarnspinnex.step(script, Yarnspinnex.start(script), %TestPlayer{})
                 end
  end

  test "context wins over vars and is read by string key first, then atom key, at every level" do
    script = compile!("N: {$gold} {$player.class} {$mood}")
    vars = [gold: 1, mood: "grumpy"]

    for context <- [
          %{"gold" => 7, "player" => %{"class" => "mage"}},
          %{gold: 7, player: %{class: "mage"}},
          [gold: 7, player: %{class: "mage"}],
          Projection.new(%{gold: 7, player: Projection.new(%{"class" => "mage"})})
        ] do
      assert TestRuntime.run(script, vars: vars, context: context).log == [
               {:line, "N", "7 mage grumpy"}
             ]
    end

    mixed = %{"gold" => 1, gold: 2, player: %{class: "x"}}
    assert TestRuntime.run(script, vars: vars, context: mixed).log == [{:line, "N", "1 x grumpy"}]
  end

  test "context never leaks into the cursor's persisted vars" do
    script = compile!("<<set $asked = true>>\nN: {$gold}")
    final = TestRuntime.run(script, context: [gold: 500, player: %TestPlayer{}])

    assert final.log == [{:line, "N", "500"}]
    assert final.vars == %{"asked" => true}
    assert final.cursor == :erlang.binary_to_term(:erlang.term_to_binary(final.cursor))
  end

  test "host functions receive the context as given and work everywhere an expression can" do
    script =
      compile!(
        """
        N: You have {gold()} gold.
        -> Buy <<if party_has_class("mage") and gold() > 100>>
            <<charge {gold()}>>
        -> Leave
            N: Bye.
        """,
        functions: TestFunctions
      )

    rich = %{party: ["mage", "rogue"], player: %TestPlayer{gold: 500}}

    assert TestRuntime.run(script, context: rich).log == [
             {:line, "N", "You have 500 gold."},
             {:options, [{"Buy", true}, {"Leave", true}]},
             {:command, "charge", [500]}
           ]

    poor = %{party: ["mage"], player: %TestPlayer{gold: 5}}

    assert TestRuntime.run(script, context: poor).log == [
             {:line, "N", "You have 5 gold."},
             {:options, [{"Buy", false}, {"Leave", true}]},
             {:line, "N", "Bye."}
           ]
  end

  test "a host function that fails is reported at the calling line" do
    defmodule Broken do
      @behaviour Yarnspinnex.HostFunctions

      @impl true
      def declared, do: [{"boom", 0}, {"missing", 0}]

      @impl true
      def call("boom", [], _context), do: raise(ArgumentError, "kaboom")
    end

    boom = compile!("N: a\nN: {boom()}", functions: Broken)
    error = assert_raise(Yarnspinnex.RuntimeError, fn -> TestRuntime.run(boom) end)
    assert Exception.message(error) == "line 4 in node \"Start\": kaboom"

    missing = compile!("N: {missing()}", functions: Broken)
    error = assert_raise(Yarnspinnex.RuntimeError, fn -> TestRuntime.run(missing) end)
    assert Exception.message(error) =~ "line 3 in node \"Start\": no function clause matching"
  end
end
