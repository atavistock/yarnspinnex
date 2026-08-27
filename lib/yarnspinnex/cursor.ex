defmodule Yarnspinnex.Cursor do
  @moduledoc """
  A position in a running dialogue: the current node, the path into it, the variables the
  dialogue owns (keyed by bare name, so `$gold` in a script is `"gold"` here), and the fingerprint
  of the script it belongs to. Plain data with no reference to the script itself and none of the
  host's context, so it can be persisted (`:erlang.term_to_binary/1`), copied, and resumed later.
  """

  @enforce_keys [:node, :script]
  defstruct node: nil, script: nil, path: [], index: 0, vars: %{}

  @typedoc "Which branch of an `<<if>>` (by position, or `:else`) or which option of a group was taken."
  @type selector :: {:if, non_neg_integer() | :else} | {:option, non_neg_integer()}

  @typedoc """
  `path` lists the enclosing `<<if>>`/option groups innermost first, each as the statement index
  of that construct in its own list plus the selector taken; `index` is the next statement in the
  innermost list. `script` is `Yarnspinnex.Script.fingerprint/0` of the script that made the cursor.
  """
  @type t :: %__MODULE__{
          node: String.t(),
          script: non_neg_integer(),
          path: [{non_neg_integer(), selector()}],
          index: non_neg_integer(),
          vars: %{optional(String.t()) => term()}
        }
end
