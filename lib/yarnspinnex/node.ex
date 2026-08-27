defmodule Yarnspinnex.Node do
  @moduledoc """
  A single parsed Yarn node: its title, the source line its header starts on, its headers, and
  its statement body.
  """

  alias Yarnspinnex.Parser.Body

  @enforce_keys [:title]
  defstruct title: nil, line: nil, headers: %{}, body: []

  @type t :: %__MODULE__{
          title: String.t(),
          line: pos_integer() | nil,
          headers: %{optional(String.t()) => String.t()},
          body: [Body.statement()]
        }
end
