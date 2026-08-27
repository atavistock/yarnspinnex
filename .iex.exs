IEx.configure(
  auto_reload: true,
  default_prompt:
    [:blue, "%prefix ", :green, "(%counter)", :white, " >"]
    |> IO.ANSI.format()
    |> IO.chardata_to_string(),
  alive_prompt:
    [:blue, "%prefix ", :yellow, "[%node] ", :green, "(%counter)", :white, " >"]
    |> IO.ANSI.format()
    |> IO.chardata_to_string(),
  history_size: 100,
  inspect: [
    binaries: :as_strings,
    pretty: true,
    limit: :infinity,
    width: 98
  ],
  width: 98
)

{:ok, hostname} = :inet.gethostname()
node = :"#{System.pid()}@#{hostname}"
Node.start(node)
