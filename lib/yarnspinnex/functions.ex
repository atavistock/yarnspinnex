defmodule Yarnspinnex.Functions do
  @moduledoc """
  Built-in Yarn Spinner expression functions. Game-specific functions belong in a
  `Yarnspinnex.HostFunctions` module passed to `Yarnspinnex.compile_string/2`.
  """

  alias Yarnspinnex.Ops

  @builtins %{
    "random" => 0,
    "random_range" => 2,
    "dice" => 1,
    "round" => 1,
    "round_places" => 2,
    "floor" => 1,
    "ceil" => 1,
    "inc" => 1,
    "dec" => 1,
    "int" => 1,
    "decimal" => 1,
    "string" => 1,
    "number" => 1,
    "bool" => 1
  }

  @doc "Every built-in as `name => arity`."
  @spec builtins() :: %{optional(String.t()) => non_neg_integer()}
  def builtins, do: @builtins

  @doc "Whether `name` is a built-in function that `call/2` implements."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(name), do: Map.has_key?(@builtins, name)

  @doc "Calls built-in `name` with already-evaluated `args`; raises on an unknown name or arity."
  @spec call(String.t(), [term()]) :: term()
  def call("random", []), do: :rand.uniform()
  def call("random_range", [low, high]), do: Enum.random(trunc(low)..trunc(high))
  def call("dice", [sides]), do: Enum.random(1..trunc(sides))
  def call("round", [number]), do: round(number)
  def call("round_places", [number, places]), do: Float.round(number * 1.0, trunc(places))
  def call("floor", [number]), do: floor(number)
  def call("ceil", [number]), do: ceil(number)

  def call("inc", [number]) do
    if number == trunc(number), do: trunc(number) + 1, else: ceil(number)
  end

  def call("dec", [number]) do
    if number == trunc(number), do: trunc(number) - 1, else: floor(number)
  end

  def call("int", [number]), do: trunc(number)
  def call("decimal", [number]), do: number - trunc(number)
  def call("string", [value]), do: Ops.to_text(value)
  def call("number", [value]) when is_binary(value), do: parse_number(value)
  def call("number", [value]), do: value
  def call("bool", [value]) when is_binary(value), do: value == "true"
  def call("bool", [value]), do: !!value

  def call(name, args) do
    raise ArgumentError, "unknown or unsupported yarn function: #{name}/#{length(args)}"
  end

  defp parse_number(text) do
    case {Integer.parse(text), Float.parse(text)} do
      {{number, ""}, _} -> number
      {_, {number, ""}} -> number
      _ -> raise ArgumentError, "cannot convert #{inspect(text)} to number"
    end
  end
end
