defmodule Disposable do
  use Agent

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
    domain = get_domain(email)
    Agent.get(__MODULE__, &MapSet.member?(&1, domain))
  end

  defp get_domain(email) do
    email
    |> String.split("@")
    |> List.last()
    |> String.downcase()
  end

  defp load_domains do
    domains_file()
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> MapSet.new()
  end

  defp domains_file do
    case Application.get_env(:disposable, :disposable_domains_file) do
      nil ->
        Application.app_dir(:disposable, "priv/domains.txt")
      path ->
        if File.exists?(path), do: path, else: Application.app_dir(:disposable, "priv/domains.txt")
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
