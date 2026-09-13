defmodule Yarnspinnex.MermaidTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Mermaid

  @source """
  title: Start
  ---
  Sally: Hi there.
  <<set $met = true>>
  -> Great, thanks!
      Sally: Glad to hear it.
  -> Buy something <<if $gold >= 10>>
      <<jump Shop>>
  Sally: See you around.
  ===
  title: Shop
  ---
  <<if $gold >= 10 and not $banned>>
      <<buy "sword" 10>>
  <<elseif $gold > 0>>
      Shopkeep: Not enough.
      <<jump Start>>
  <<else>>
      <<stop>>
  <<endif>>
  ===
  title: Unused
  ---
  ===
  """

  setup do
    {:ok, script} = Yarnspinnex.compile_string(@source)
    %{script: script}
  end

  test "node_graph lists every node with the start as a stadium and one edge per jump", %{
    script: script
  } do
    assert Mermaid.node_graph(script) == """
           flowchart TD
             n_Start(["Start"])
             n_Shop["Shop"]
             n_Unused["Unused"]
             n_Start --> n_Shop
             n_Shop --> n_Start\
           """
  end

  test "flowchart groups statements per node and follows control flow", %{script: script} do
    output = Mermaid.flowchart(script)
    lines = String.split(output, "\n")

    assert hd(lines) == "flowchart TD"
    assert ~s(  subgraph n_Start["Start"]) in lines
    assert ~s(    n_Start_1["Sally: Hi there.<br/>$met = true"]) in lines
    assert ~s(    n_Start_2{{"choice"}}) in lines
    assert ~s(    n_Start_3["Sally: See you around."]) in lines
    assert ~s(    n_Start_4["Sally: Glad to hear it."]) in lines
    assert ~s(    n_Start_5["jump Shop"]) in lines
    assert "  n_Start_1 --> n_Start_2" in lines
    assert ~s(  n_Start_2 -->|"Great, thanks!"| n_Start_4) in lines

    assert ~s(  n_Start_2 -->|"Buy something #60;#60;if $gold #62;= 10#62;#62;"| n_Start_5) in lines

    assert "  n_Start_4 --> n_Start_3" in lines
    assert "  n_Start_5 --> n_Shop_1" in lines
    assert "  n_Start_3 --> done" in lines

    assert ~s(    n_Shop_1{"if"}) in lines
    assert ~s(    n_Shop_2["#60;#60;buy #34;sword#34; 10#62;#62;"]) in lines
    assert ~s(    n_Shop_3["Shopkeep: Not enough."]) in lines
    assert ~s(    n_Shop_4["stop"]) in lines
    assert ~s(  n_Shop_1 -->|"$gold #62;= 10 and not $banned"| n_Shop_2) in lines
    assert ~s(  n_Shop_1 -->|"$gold #62; 0"| n_Shop_3) in lines
    assert ~s(  n_Shop_1 -->|"else"| n_Shop_4) in lines
    assert "  n_Shop_4 --> done" in lines
    assert "  n_Shop_2 --> done" in lines
    assert "  n_Shop_3 --> n_Start_1" in lines

    assert ~s(    n_Unused_1["Unused"]) in lines
    assert ~s(  done\(\("end"\)\)) in lines
  end

  test "flowchart restricted to some nodes draws outside jump targets as plain boxes", %{
    script: script
  } do
    lines = script |> Mermaid.flowchart(nodes: ["Start"]) |> String.split("\n")

    assert ~s(  subgraph n_Start["Start"]) in lines
    refute ~s(  subgraph n_Shop["Shop"]) in lines
    assert ~s(  n_Shop_1["Shop"]) in lines
    assert "  n_Start_5 --> n_Shop_1" in lines
  end

  test "flowchart with no edge to the terminal omits it" do
    {:ok, script} = Yarnspinnex.compile_string("title: Loop\n---\n<<jump Loop>>\n===\n")
    refute Mermaid.flowchart(script) =~ "done"
  end

  test "expression_text prints back Yarn source with minimal parentheses" do
    parse = &Yarnspinnex.Parser.Expression.parse!/1

    for source <- [
          ~S|$a + $b * 2|,
          ~S|($a + $b) * 2|,
          ~S|$a - ($b - $c)|,
          ~S|$a - $b - $c|,
          ~S|not ($a and $b)|,
          ~S|-($a + 1)|,
          ~S|visited("Shop") or $gold >= 10 and $name == "Sally"|,
          ~S|$player.name + " rocks"|,
          ~S|$a or ($b xor $c)|
        ] do
      assert Mermaid.expression_text(parse.(source)) == source
    end
  end

  test "escape neutralizes characters Mermaid would read as markup or syntax" do
    assert Mermaid.escape(~S/a "b" <c> {d} [e] |f| #g& (h)/) ==
             "a #34;b#34; #60;c#62; #123;d#125; #91;e#93; #124;f#124; #35;g#38; #40;h#41;"
  end
end
