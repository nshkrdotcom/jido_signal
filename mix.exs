defmodule JidoSignal.MixProject do
  use Mix.Project

  @version "1.0.0"

  def vsn do
    @version
  end

  def project do
    [
      app: :jido_signal,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "Jido Signal",
      description: "A toolkit for building autonomous, distributed agent systems in Elixir",
      source_url: "https://github.com/agentjido/jido_signal",
      homepage_url: "https://github.com/agentjido/jido_signal",
      package: package(),
      docs: docs()
    ]
  end

  def package do
    [
      name: "jido_signal",
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Jido"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/agentjido/jido_signal"}
    ]
  end

  def docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Development & Test Dependencies
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:dev, :test]},
      {:expublish, "~> 2.7", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mock, "~> 0.3.0", only: :test},
      {:mimic, "~> 1.11", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
