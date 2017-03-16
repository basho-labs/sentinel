defmodule SentinelCore.Mixfile do
  use Mix.Project

  def project do
    [app: :sentinel_core,
     version: "0.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     test_coverage: [tool: ExCoveralls],
     preferred_cli_env: ["coveralls": :test],
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:crypto, :logger, :dns],
     mod: {SentinelCore.Application, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:quixir, "~> 0.9", only: :test},
      {:excoveralls, "~> 0.6", only: :test},
      {:distillery, "~> 1.1"},
      {:emqttc, git: "https://github.com/emqtt/emqttc.git", branch: "master"},
      {:socket, "~> 0.3.5"},
      {:dns, "~> 0.0.4"},
      {:lager, ~r/.*/, [env: :prod, git: "https://github.com/basho/lager.git", branch: "master", manager: :rebar3]}
    ]
  end
end
