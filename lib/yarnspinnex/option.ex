defmodule Yarnspinnex.Option do
  @moduledoc """
  One choice in a `->` option group, as returned by `Yarnspinnex.step/3`. `index` is what
  `Yarnspinnex.choose/4` takes; `enabled?` reflects the option's trailing `<<if>>` and is false
  for choices that should be shown but cannot be picked. `tags` and `id` come from the `#tags`
  written after the option, as on a `Yarnspinnex.Line`.
  """

  @enforce_keys [:index, :text, :enabled?]
  defstruct [:index, :text, :enabled?, tags: [], id: nil]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          text: String.t(),
          enabled?: boolean(),
          tags: [String.t()],
          id: String.t() | nil
        }
end
