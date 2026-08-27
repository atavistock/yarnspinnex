defmodule Yarnspinnex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/atavistock/yarnspinnex"

  def project do
    [
      app: :yarnspinnex,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Yarn Spinner dialogue for Elixir: compile scripts to plain data and step through them with a serializable cursor.",
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: []]
  end

  defp deps do
    [{:ex_doc, "~> 0.40", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE.txt)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_url: @source_url]
  end
end
