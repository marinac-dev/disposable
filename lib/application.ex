defmodule Disposable.Application do
  use Application

  @moduledoc """
  The main application module for Disposable.
  """

  @impl true
  def start(_type, _args) do
    children = [
      # List all child processes to be supervised
      Disposable
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Disposable.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
