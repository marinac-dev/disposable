defmodule Disposable.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/marinac-dev/disposable"

  def project do
    [
      app: :disposable,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34.2"}
    ]
  end

  defp description do
    "A library for checking if an email address is from a disposable email service."
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "priv/domains.txt"],
      maintainers: ["Your Name"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
