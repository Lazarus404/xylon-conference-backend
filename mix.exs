defmodule XylonConferenceBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :xylon_conference_backend,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:mcu_nif],
      deps: deps(),
      description: "Xylon conference room SFU backend (audio + video).",
      source_url: "https://github.com/Lazarus404/xylon_conference_backend",
      docs: [
        extras: ["README.md"],
        main: "readme"
      ],
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:xylon, "~> 0.1.0"},
      {:xylon_datachannel_backend, "~> 0.1.0"},
      {:xylon_record, "~> 0.1.0"},
      {:telemetry, "~> 1.0"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Lazarus404/xylon_conference_backend"},
      files: ~w(lib c_src priv mix.exs README.md LICENSE Makefile .gitignore)
    ]
  end
end
