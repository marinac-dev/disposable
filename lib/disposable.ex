defmodule Disposable do
  @moduledoc """
  Provides functionality to check if an email address belongs to a disposable email service.
  Uses an Agent process to maintain an in-memory cache of disposable domains for efficient lookups.
  """

  use Agent
  require Logger

  @typedoc "A disposable email"
  @type email :: String.t()
  @typedoc "A disposable domain name"
  @type domain :: String.t()

  @doc """
  Starts the Disposable domain cache Agent.

  The Agent is registered under the current module name and initialized with
  domains loaded from the configured file path.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(&load_domains/0, name: __MODULE__)
  end

  @doc """
  Checks if an email address belongs to a disposable email service.

  Returns `false` if the email is invalid or if the Agent process is not running.

  ## Examples

      iex> Disposable.check("user@example.com")
      false

      iex> Disposable.check("test@alltempmail.com")
      true
  """
  @spec check(email()) :: boolean() | {:error, :not_running} | {:error, :invalid_email} | no_return()
  def check(email) when is_binary(email) do
    with {:ok, pid} <- ensure_running(),
         {:ok, domain} <- extract_domain(email) do
      Agent.get(pid, &MapSet.member?(&1, domain))
    else
      {:error, :not_running} ->
        Logger.error("Disposable email Agent is not running")
        raise Disposable.Exception, message: "Disposable email Agent is not running"

      {:error, :invalid_email} ->
        false
    end
  end

  @doc """
  Reloads the disposable domains from the configured file into memory.

  Useful for updating the domain list without restarting the application.
  """
  @spec reload() :: :ok
  def reload do
    data = load_domains()
    Agent.update(__MODULE__, fn _state -> data end)
  end

  @doc """
  Load domains from a URL into memory.
  """
  def load_url(url) do
    case Disposable.Http.get(url) do
      {:ok, 200, _headers, body} ->
        data = to_string(body) |> String.split("\n")

        parsed =
          data
          |> Stream.map(&String.trim/1)
          |> MapSet.new()

        Agent.update(__MODULE__, fn _state -> parsed end)
    end
  end

  # Private Functions

  @spec ensure_running() :: {:ok, pid()} | {:error, :not_running}
  defp ensure_running do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_running}
    end
  end

  @spec extract_domain(email()) :: {:ok, domain()} | {:error, :invalid_email}
  defp extract_domain(email) do
    case String.split(email, "@") do
      [_local_part, domain] -> {:ok, String.downcase(domain)}
      _invalid -> {:error, :invalid_email}
    end
  end

  @spec load_domains() :: MapSet.t()
  defp load_domains do
    domains_file()
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> MapSet.new()
  end

  @spec domains_file() :: String.t()
  defp domains_file do
    default_path = Application.app_dir(:disposable, "priv/domains.txt")

    Application.get_env(:disposable, :disposable_domains_file)
    |> determine_file_path(default_path)
  end

  @spec determine_file_path(String.t() | nil, String.t()) :: String.t()
  defp determine_file_path(nil, default_path), do: default_path

  defp determine_file_path(path, default_path),
    do: if(File.exists?(path), do: path, else: default_path)
end
