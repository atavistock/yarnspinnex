defmodule Yarnspinnex.TestRuntime do
  @moduledoc """
  Drives a script through `Yarnspinnex.step/3` for tests: records every event in `log`, keeps
  the final `vars`, and picks options with `choose` (a function from the enabled options to one
  of them, defaulting to the first). `context` is passed through to every step untouched.
  """

  alias Yarnspinnex.Line

  @doc "Runs `script` from its start node; returns `%{log: events, vars: vars, cursor: cursor}`."
  def run(script, opts \\ []) do
    vars = Keyword.get(opts, :vars, %{})
    context = Keyword.get(opts, :context, %{})
    choose = Keyword.get(opts, :choose, &hd/1)
    loop(script, Yarnspinnex.start(script, vars), choose, context, [])
  end

  defp loop(script, cursor, choose, context, log) do
    case Yarnspinnex.step(script, cursor, context) do
      {:line, %Line{speaker: speaker, text: text}, cursor} ->
        loop(script, cursor, choose, context, [{:line, speaker, text} | log])

      {:command, name, args, cursor} ->
        loop(script, cursor, choose, context, [{:command, name, args} | log])

      {:options, options, cursor} ->
        chosen = options |> Enum.filter(& &1.enabled?) |> choose.()
        {:ok, cursor} = Yarnspinnex.choose(script, cursor, chosen.index, context)
        offered = Enum.map(options, &{&1.text, &1.enabled?})
        loop(script, cursor, choose, context, [{:options, offered} | log])

      {:done, cursor} ->
        %{log: Enum.reverse(log), vars: cursor.vars, cursor: cursor}
    end
  end
end
