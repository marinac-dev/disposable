defmodule Disposable do
  use Agent

  require Logger

  @moduledoc """
  Checks if an email address is from a disposable email service.
  Uses an Agent to keep domains in memory for faster checking.
  """

  def start_link(_opts) do
    Agent.start_link(&load_domains/0, name: __MODULE__)
  end

  @doc """
  Checks if an email address is from a disposable email service.

  ## Examples

      iex> Disposable.check("test@example.com")
      false

      iex> Disposable.check("test@alltempmail.com")
      true

  """
  def check(email) do
    if Process.whereis(__MODULE__) do
      domain = get_domain(email)

      if domain do
        Agent.get(__MODULE__, &MapSet.member?(&1, domain))
      else
        false
      end
    else
      Logger.error("Disposable E-mail Agent is not running.")
      false
    end
  end

  defp get_domain(email) do
    case String.split(email, "@") do
      [_local_part, domain] -> String.downcase(domain)
      _ -> nil
    end
  end

  defp load_domains do
    domains_file()
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> MapSet.new()
  end

  defp domains_file do
    default_path = Application.app_dir(:disposable, "priv/domains.txt")

    case Application.get_env(:disposable, :disposable_domains_file) do
      nil -> default_path
      path -> if File.exists?(path), do: path, else: default_path
    end
  end

  @doc """
  Reloads the domains from the file into memory.
  Useful for updating the list without restarting the application.
  """
  def reload do
    Agent.update(__MODULE__, fn _state -> load_domains() end)
  end
end
