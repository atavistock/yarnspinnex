defmodule Yarnspinnex.Line do
  @moduledoc """
  One line of dialogue as returned by `Yarnspinnex.step/3`: the speaker, the text with its
  interpolations applied, and the `#tags` written after it. `id` is the value of the `#line:`
  tag when present - Yarn's localization key for the line.
  """

  @enforce_keys [:text]
  defstruct speaker: nil, text: "", tags: [], id: nil

  @type t :: %__MODULE__{
          speaker: String.t() | nil,
          text: String.t(),
          tags: [String.t()],
          id: String.t() | nil
        }
end
