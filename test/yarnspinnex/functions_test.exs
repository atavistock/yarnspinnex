defmodule Yarnspinnex.FunctionsTest do
  use ExUnit.Case, async: true

  alias Yarnspinnex.Functions

  test "builtin? knows the standard library and nothing else" do
    assert Functions.builtin?("random_range")
    refute Functions.builtin?("length")
  end

  test "random_range returns a value within the inclusive bounds" do
    assert Functions.call("random_range", [1, 1]) == 1
    assert Enum.all?(1..50, fn _ -> Functions.call("random_range", [2, 5]) in 2..5 end)
  end

  test "dice returns a value between 1 and the given sides" do
    assert Enum.all?(1..50, fn _ -> Functions.call("dice", [6]) in 1..6 end)
  end

  test "round, floor, and ceil" do
    assert Functions.call("round", [2.5]) == 3
    assert Functions.call("floor", [2.9]) == 2
    assert Functions.call("ceil", [2.1]) == 3
  end

  test "round_places rounds to the given number of decimal places" do
    assert Functions.call("round_places", [3.14159, 2]) == 3.14
  end

  test "inc and dec on integers step by one" do
    assert Functions.call("inc", [4]) == 5
    assert Functions.call("dec", [4]) == 3
  end

  test "inc and dec on non-integers round toward the nearest integer" do
    assert Functions.call("inc", [4.2]) == 5
    assert Functions.call("dec", [4.8]) == 4
  end

  test "int truncates and decimal returns the fractional part" do
    assert Functions.call("int", [4.7]) == 4
    assert Functions.call("decimal", [4.75]) == 0.75
  end

  test "string converts values to their dialogue text form" do
    assert Functions.call("string", [42]) == "42"
    assert Functions.call("string", [true]) == "true"
    assert Functions.call("string", [5.0]) == "5"
    assert Functions.call("string", [2.5]) == "2.5"
  end

  test "number parses integer strings as integers, float strings as floats, and passes numbers through" do
    assert Functions.call("number", ["42"]) === 42
    assert Functions.call("number", ["3.5"]) === 3.5
    assert Functions.call("number", [7]) === 7
  end

  test "number raises on a non-numeric string" do
    assert_raise ArgumentError, fn -> Functions.call("number", ["nope"]) end
  end

  test "bool parses boolean strings and coerces other values" do
    assert Functions.call("bool", ["true"]) == true
    assert Functions.call("bool", ["false"]) == false
    assert Functions.call("bool", [0]) == true
    assert Functions.call("bool", [nil]) == false
  end

  test "unknown functions and wrong arities raise ArgumentError" do
    assert_raise ArgumentError, ~r/unknown or unsupported yarn function: nope\/1/, fn ->
      Functions.call("nope", [1])
    end

    assert_raise ArgumentError, ~r/unknown or unsupported yarn function: dice\/2/, fn ->
      Functions.call("dice", [1, 2])
    end
  end
end
