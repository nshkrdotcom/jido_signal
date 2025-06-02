defmodule Jido.Signal.MixProject do
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
      elixirc_paths: elixirc_paths(Mix.env()),
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

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      extra_applications: [:logger],
      mod: {Jido.Signal.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Deps
      {:ex_dbug, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:msgpax, "~> 2.3"},
      {:nimble_options, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:private, "~> 0.1.2"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:typed_struct, "~> 0.3.0"},
      {:uniq, "~> 0.6.1"},

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
