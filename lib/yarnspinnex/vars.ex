defmodule Yarnspinnex.Vars do
  @moduledoc """
  Name lookup shared by the interpreter and `Yarnspinnex.Ops`: `$player` finds `"player"` or
  `:player` in a map or `Yarnspinnex.Projection`, string key first. A keyword list is accepted at
  the top level only, as context (`lookup!/1`) or vars (`normalize/1`); nested values are maps.
  """

  alias Yarnspinnex.Projection

  @typedoc "What a host may pass as context: read by name, never copied or rewritten."
  @type collection :: %{optional(atom() | String.t()) => term()} | keyword() | Projection.t()

  @typedoc "What a host may pass as variables: normalized once into the cursor."
  @type vars :: %{optional(atom() | String.t()) => term()} | keyword()

  @typedoc "What `fetch/2` reads: a context or field value after `lookup!/1`."
  @type lookup :: %{optional(atom() | String.t()) => term()} | Projection.t()

  @doc "Looks `name` up as a string key, then as an existing atom; `:error` when neither is there."
  @spec fetch(lookup(), String.t()) :: {:ok, term()} | :error
  def fetch(%Projection{fields: fields}, name), do: fetch(fields, name)

  def fetch(map, name) when is_map(map) do
    with :error <- Map.fetch(map, name),
         {:ok, atom} <- existing_atom(name) do
      Map.fetch(map, atom)
    end
  end

  @doc """
  The host's `context` as `fetch/2` reads it: a map or `Yarnspinnex.Projection` as is, a keyword
  list as a map. Raises on anything else, a domain struct included.
  """
  @spec lookup!(term()) :: lookup()
  def lookup!(%Projection{} = projection), do: projection

  def lookup!(%module{}) do
    raise ArgumentError,
          "context must be a map, a keyword list, or a Yarnspinnex.Projection, " <>
            "got a #{inspect(module)} struct"
  end

  def lookup!(context) when is_map(context), do: context

  # Reversed so that, as in a keyword list, the first entry for a name wins.
  def lookup!(context) when is_list(context) do
    if Enum.all?(context, &name_pair?/1) do
      context |> Enum.reverse() |> Map.new()
    else
      raise ArgumentError,
            "context list must hold {name, value} pairs keyed by atom or string, " <>
              "got #{inspect(context)}"
    end
  end

  def lookup!(other) do
    raise ArgumentError,
          "context must be a map, a keyword list, or a Yarnspinnex.Projection, got #{inspect(other)}"
  end

  defp name_pair?({name, _value}) when is_atom(name) or is_binary(name), do: true
  defp name_pair?(_other), do: false

  @doc "Builds the string-keyed variable map a cursor carries from a map or keyword list."
  @spec normalize(vars()) :: %{optional(String.t()) => term()}
  def normalize(%module{}) do
    raise ArgumentError,
          "vars must be a map or keyword list of names, got a #{inspect(module)} struct"
  end

  def normalize(vars) when is_map(vars) or is_list(vars) do
    Map.new(vars, fn {name, value} -> {to_string(name), value} end)
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
