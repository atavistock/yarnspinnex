defmodule Yarnspinnex.Vars do
  @moduledoc """
  Name lookup shared by the interpreter and `Yarnspinnex.Ops`: a script's `$player` finds
  `"player"` or `:player` in a map, a keyword list, or a `Yarnspinnex.Projection`, string key
  first. `normalize/1` turns a host's variable collection into the string-keyed map a cursor keeps.
  """

  alias Yarnspinnex.Projection

  @typedoc "What a host may pass as context: read by name, never copied or rewritten."
  @type collection :: %{optional(atom() | String.t()) => term()} | keyword() | Projection.t()

  @typedoc "What a host may pass as variables: normalized once into the cursor."
  @type vars :: %{optional(atom() | String.t()) => term()} | keyword()

  @doc "Looks `name` up as a string key, then as an existing atom; `:error` when neither is there."
  @spec fetch(collection(), String.t()) :: {:ok, term()} | :error
  def fetch(%Projection{fields: fields}, name), do: fetch(fields, name)

  def fetch(map, name) when is_map(map) do
    with :error <- Map.fetch(map, name),
         {:ok, atom} <- existing_atom(name) do
      Map.fetch(map, atom)
    end
  end

  def fetch(list, name) when is_list(list) do
    with nil <- List.keyfind(list, name, 0),
         {:ok, atom} <- existing_atom(name),
         nil <- List.keyfind(list, atom, 0) do
      :error
    else
      {_key, value} -> {:ok, value}
      :error -> :error
    end
  end

  @doc "Raises unless `context` is a plain map, a keyword list, or a `Yarnspinnex.Projection`."
  @spec check_context!(term()) :: :ok
  def check_context!(%Projection{}), do: :ok

  def check_context!(%module{}) do
    raise ArgumentError,
          "context must be a map, a keyword list, or a Yarnspinnex.Projection, " <>
            "got a #{inspect(module)} struct"
  end

  def check_context!(context) when is_map(context) or is_list(context), do: :ok

  def check_context!(other) do
    raise ArgumentError,
          "context must be a map, a keyword list, or a Yarnspinnex.Projection, got #{inspect(other)}"
  end

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
