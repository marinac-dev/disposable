defmodule Disposable.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/marinac-dev/disposable"

  def project do
    [
      app: :disposable,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        "test.unit": :test,
        "test.integration": :test,
        check: :test
      ],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Disposable",
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {Disposable.Application, []},
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      {:castore, "~> 1.0"},
      {:req, "~> 0.7.2"},
      {:ex_doc, "~> 0.34.2", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "test.unit": "test --only unit",
      "test.integration": "test --only integration",
      check: ["format --check-formatted", "test --warnings-as-errors"]
    ]
  end

  defp description do
    "A library for checking if an email address is from a disposable email service."
  end

  defp package do
    [
      name: "disposable",
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "guides",
        "LICENSE.md",
        "priv/domains.txt"
      ],
      maintainers: ["marinac-dev"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/migrating-to-0.2.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
