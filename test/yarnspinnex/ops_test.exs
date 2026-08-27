defmodule Yarnspinnex.OpsTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Ops

  test "adds two numbers" do
    assert Ops.add(2, 3) == 5
    assert Ops.add(2.5, 1) == 3.5
  end

  test "concatenates when either side is a string, rendering numbers as dialogue text" do
    assert Ops.add("Score: ", 5) == "Score: 5"
    assert Ops.add(5, " points") == "5 points"
    assert Ops.add("a", "b") == "ab"
    assert Ops.add("Score: ", 5.0) == "Score: 5"
  end

  test "arithmetic on a non-number raises with the operator and operands" do
    assert_raise ArgumentError, "cannot apply + to nil and 1", fn -> Ops.add(nil, 1) end
    assert_raise ArgumentError, "cannot apply - to \"a\" and 1", fn -> Ops.binop(:-, "a", 1) end
    assert_raise ArgumentError, "cannot apply * to nil and 2", fn -> Ops.binop(:*, nil, 2) end
  end

  test "remainder works on integers and floats" do
    assert Ops.binop(:%, 7, 3) === 1
    assert Ops.binop(:%, 5.5, 2) === 1.5
    assert Ops.binop(:%, -7, 3) === -1
  end

  test "ordering comparisons require numbers on both sides" do
    assert Ops.binop(:<, 1, 2.5)
    assert Ops.binop(:>=, 3, 3)

    assert_raise ArgumentError, "cannot apply > to nil and 5", fn -> Ops.binop(:>, nil, 5) end
    assert_raise ArgumentError, "cannot apply < to \"a\" and 5", fn -> Ops.binop(:<, "a", 5) end
  end

  test "to_text drops the decimal point from whole floats and leaves everything else alone" do
    assert Ops.to_text(5.0) == "5"
    assert Ops.to_text(-0.0) == "0"
    assert Ops.to_text(2.5) == "2.5"
    assert Ops.to_text(1.0e20) == "1.0e20"
    assert Ops.to_text(42) == "42"
    assert Ops.to_text(nil) == ""
    assert Ops.to_text(true) == "true"
  end

  test "get_field reads a plain map field by string or atom key" do
    assert Ops.get_field(%{"strength" => 15}, "strength") == 15
    assert Ops.get_field(%{strength: 15}, "strength") == 15
    assert Ops.get_field(%{"strength" => 1, strength: 2}, "strength") == 1
  end

  test "get_field returns nil for an unknown field or a nil base" do
    assert Ops.get_field(%{strength: 1}, "nonexistent") == nil
    assert Ops.get_field(nil, "strength") == nil
  end

  test "get_field refuses a struct and points at the projection" do
    player = %Yarnspinnex.TestPlayer{strength: 15, name: "Aaron"}

    message =
      "cannot read field \"strength\" on a Yarnspinnex.TestPlayer struct: " <>
        "dialogue reads a plain map or a Yarnspinnex.Projection, so build a projection in the host"

    assert_raise ArgumentError, message, fn -> Ops.get_field(player, "strength") end
  end

  test "get_field refuses reserved field names on any base" do
    for field <- ["__struct__", "__meta__", "_source"] do
      assert_raise ArgumentError, ~r/cannot read reserved field/, fn ->
        Ops.get_field(%{strength: 1}, field)
      end
    end

    # A projection may carry a reference back to its entity; dialogue still cannot read it.
    projection = %{class: "mage", __source__: %Yarnspinnex.TestPlayer{}}

    assert Ops.get_field(projection, "class") == "mage"
    assert projection.__source__ == %Yarnspinnex.TestPlayer{}

    assert_raise ArgumentError, ~r/cannot read reserved field/, fn ->
      Ops.get_field(projection, "__source__")
    end
  end

  test "get_field raises when accessing a field on a non-map value" do
    assert_raise ArgumentError, fn -> Ops.get_field(5, "strength") end
  end

  test "equality refuses non-scalars instead of quietly answering false" do
    player = %Yarnspinnex.TestPlayer{}

    message =
      "cannot compare a Yarnspinnex.TestPlayer struct with ==: " <>
        "dialogue compares numbers, strings, booleans, and nil, so build a projection in the host"

    assert_raise ArgumentError, message, fn -> Ops.binop(:==, player, "mage") end

    assert_raise ArgumentError, ~r/cannot compare a map with !=/, fn ->
      Ops.binop(:!=, %{a: 1}, "mage")
    end

    assert_raise ArgumentError, ~r/cannot compare a list with ==/, fn ->
      Ops.binop(:==, ["mage"], "mage")
    end
  end

  test "equality still compares every scalar, including nil" do
    assert Ops.binop(:==, 1, 1.0)
    assert Ops.binop(:!=, "1", 1)
    refute Ops.binop(:==, nil, 0)
    assert Ops.binop(:==, nil, nil)
    assert Ops.binop(:!=, nil, "mage")
    assert Ops.binop(:==, true, true)
  end

  test "to_text refuses non-scalars instead of a protocol error" do
    assert_raise ArgumentError,
                 ~r/cannot render a Yarnspinnex.TestPlayer struct as dialogue text/,
                 fn ->
                   Ops.to_text(%Yarnspinnex.TestPlayer{})
                 end

    assert_raise ArgumentError, ~r/cannot render a map as dialogue text/, fn ->
      Ops.to_text(%{a: 1})
    end

    assert_raise ArgumentError, ~r/cannot render a list as dialogue text/, fn ->
      Ops.to_text([1, 2])
    end
  end
end
