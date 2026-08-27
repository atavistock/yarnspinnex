defmodule Yarnspinnex.ProjectionTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Ops
  alias Yarnspinnex.Projection
  alias Yarnspinnex.TestPlayer
  alias Yarnspinnex.TestRuntime

  defp compile!(body, opts \\ []) do
    {:ok, script} = Yarnspinnex.compile_string("title: Start\n---\n#{body}\n===\n", opts)
    script
  end

  test "a projection reads like a plain map, by string or atom key, and its source is out of reach" do
    player = %TestPlayer{name: "Aaron", gold: 12}
    projection = Projection.new(%{"level" => 5, class: "mage"}, source: player)

    assert Ops.get_field(projection, "class") == "mage"
    assert Ops.get_field(projection, "level") == 5
    assert Ops.get_field(projection, "missing") == nil
    assert projection.source == player

    assert_raise ArgumentError, ~r/cannot read reserved field/, fn ->
      Ops.get_field(projection, "__struct__")
    end
  end

  test "a projection works as one context value or as the whole context" do
    script = compile!("N: {$player.class} in {$location}")
    player = Projection.new(%{class: "mage"}, source: %TestPlayer{})

    assert TestRuntime.run(script, context: [player: player, location: "the bakery"]).log ==
             [{:line, "N", "mage in the bakery"}]

    whole = Projection.new(%{player: player, location: "the bakery"}, source: :world)
    assert TestRuntime.run(script, context: whole).log == [{:line, "N", "mage in the bakery"}]
  end

  test "host functions receive the projection itself, source included" do
    defmodule SourceFunctions do
      @behaviour Yarnspinnex.HostFunctions

      @impl true
      def declared, do: [{"real_gold", 0}]

      @impl true
      def call("real_gold", [], context), do: context.player.source.gold
    end

    script = compile!("N: {$player.class} has {real_gold()}", functions: SourceFunctions)
    context = %{player: Projection.new(%{class: "mage"}, source: %TestPlayer{gold: 99})}

    assert TestRuntime.run(script, context: context).log == [{:line, "N", "mage has 99"}]
  end

  test "a projection is not a scalar, so comparing or rendering one is an error" do
    projection = Projection.new(%{class: "mage"})

    assert_raise ArgumentError, ~r/cannot compare a projection with ==/, fn ->
      Ops.binop(:==, projection, "mage")
    end

    assert_raise ArgumentError, ~r/cannot render a projection as dialogue text/, fn ->
      Ops.to_text(projection)
    end
  end
end
