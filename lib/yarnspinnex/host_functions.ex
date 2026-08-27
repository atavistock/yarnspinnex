defmodule Yarnspinnex.HostFunctions do
  @moduledoc """
  Behaviour for the game-specific functions a script may call, beyond `Yarnspinnex.Functions`.

  `declared/0` is read at compile time: it validates every call in the script and doubles as the
  manifest an editor can list. `call/3` receives the context passed to `Yarnspinnex.step/3`
  exactly as the host gave it.
  """

  @doc "Every callable function as `{name, arity}`; the compiler rejects any call not listed here."
  @callback declared() :: [{String.t(), non_neg_integer()}]

  @doc "Evaluates a declared function against the caller's context."
  @callback call(name :: String.t(), args :: [term()], context :: term()) :: term()
end
