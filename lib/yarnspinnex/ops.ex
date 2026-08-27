defmodule Yarnspinnex.Ops do
  @moduledoc """
  Operator semantics for `Yarnspinnex.Interpreter`: `binop/3` for every binary operator except
  `and`/`or` (those short-circuit in the interpreter), `get_field/2` for `.` access, and
  `to_text/1` for how values render inside dialogue text.

  Dialogue reads scalars. A struct, map, or list reaching a comparison or a line of text is a
  missing projection in the host, and every path here says so rather than failing quietly.
  """

  @max_integral_float 1.0e15

  @typedoc "Every binary operator an expression can contain; `and`, `or`, and `xor` are evaluated by the interpreter."
  @type operator :: :+ | :- | :* | :/ | :% | :== | :!= | :< | :> | :<= | :>= | :and | :or | :xor

  @spec binop(operator(), term(), term()) :: term()
  def binop(:+, left, right), do: add(left, right)
  def binop(:-, left, right) when is_number(left) and is_number(right), do: left - right
  def binop(:*, left, right) when is_number(left) and is_number(right), do: left * right
  def binop(:/, left, right) when is_number(left) and is_number(right), do: left / right
  def binop(:%, left, right) when is_integer(left) and is_integer(right), do: rem(left, right)

  def binop(:%, left, right) when is_number(left) and is_number(right),
    do: :math.fmod(left, right)

  def binop(:==, left, right), do: comparable!(left, :==) == comparable!(right, :==)
  def binop(:!=, left, right), do: comparable!(left, :!=) != comparable!(right, :!=)
  def binop(:<, left, right) when is_number(left) and is_number(right), do: left < right
  def binop(:>, left, right) when is_number(left) and is_number(right), do: left > right
  def binop(:<=, left, right) when is_number(left) and is_number(right), do: left <= right
  def binop(:>=, left, right) when is_number(left) and is_number(right), do: left >= right

  def binop(op, left, right) do
    raise ArgumentError, "cannot apply #{op} to #{inspect(left)} and #{inspect(right)}"
  end

  @doc """
  Reads a condition as a boolean. `nil` (an unset variable) counts as false; a number, string,
  or anything else in a condition is an error, so `$count` must be written `$count > 0`.
  """
  @spec boolean!(term()) :: boolean()
  def boolean!(true), do: true
  def boolean!(false), do: false
  def boolean!(nil), do: false

  def boolean!(value) do
    raise ArgumentError,
          "expected true or false in a condition, got #{describe(value)}: " <>
            "compare it (such as > 0 or == \"yes\") or convert it with bool()"
  end

  @doc "Yarn `+`: numeric addition, or concatenation when either side is a string."
  @spec add(term(), term()) :: number() | String.t()
  def add(left, right) when is_binary(left) or is_binary(right) do
    to_text(left) <> to_text(right)
  end

  def add(left, right) when is_number(left) and is_number(right), do: left + right

  def add(left, right) do
    raise ArgumentError, "cannot apply + to #{inspect(left)} and #{inspect(right)}"
  end

  @doc """
  Reads `field` off a plain map or a `Yarnspinnex.Projection`, by string key or atom key; `nil`
  for a missing field or a `nil` base.

  Domain structs are refused: dialogue reads a view the host builds, not the object itself, so
  content never depends on the shape of a schema. Fields whose name begins with `_` are refused
  outright, which keeps `__struct__` and Ecto's `__meta__` closed off.
  """
  @spec get_field(term(), String.t()) :: term()
  def get_field(_term, "_" <> _ = field) do
    raise ArgumentError, "cannot read reserved field #{inspect(field)} from dialogue"
  end

  def get_field(nil, _field), do: nil

  def get_field(%Yarnspinnex.Projection{} = projection, field), do: fetch_field(projection, field)

  def get_field(%module{}, field) do
    raise ArgumentError,
          "cannot read field #{inspect(field)} on a #{inspect(module)} struct: " <>
            "dialogue reads a plain map or a Yarnspinnex.Projection, " <>
            "so build a projection in the host"
  end

  def get_field(term, field) when is_map(term), do: fetch_field(term, field)

  def get_field(term, field) do
    raise ArgumentError, "cannot access field #{inspect(field)} on #{inspect(term)}"
  end

  defp fetch_field(fields, field) do
    case Yarnspinnex.Vars.fetch(fields, field) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @doc "Renders a value as dialogue text: whole-number floats print without a decimal point."
  @spec to_text(term()) :: String.t()
  def to_text(value) when is_float(value) do
    if value == trunc(value) and abs(value) < @max_integral_float do
      Integer.to_string(trunc(value))
    else
      to_string(value)
    end
  end

  def to_text(value) when is_integer(value) or is_binary(value), do: to_string(value)
  def to_text(value) when is_boolean(value) or is_nil(value), do: to_string(value)

  def to_text(value) do
    raise ArgumentError,
          "cannot render #{describe(value)} as dialogue text: " <>
            "dialogue shows numbers, strings, booleans, and nil, so build a projection in the host"
  end

  defp comparable!(value, _op)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value) do
    value
  end

  defp comparable!(value, op) do
    raise ArgumentError,
          "cannot compare #{describe(value)} with #{op}: " <>
            "dialogue compares numbers, strings, booleans, and nil, so build a projection in the host"
  end

  defp describe(%Yarnspinnex.Projection{}), do: "a projection"
  defp describe(%module{}), do: "a #{inspect(module)} struct"
  defp describe(value) when is_map(value), do: "a map"
  defp describe(value) when is_list(value), do: "a list"
  defp describe(value), do: inspect(value)
end
