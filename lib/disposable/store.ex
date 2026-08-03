defmodule Disposable.Store do
  @moduledoc """
  Owns the active domain generation and serializes source replacements.

  The named ETS table contains only the active table identifier. Domain reads
  use that identifier directly and never call this GenServer.
  """

  use GenServer

  @name Disposable
  @metadata_table :disposable_domains
  @call_timeout 60_000

  @type state :: %{
          metadata_table: :ets.tid(),
          active_table: :ets.tid(),
          source: term(),
          url_options: keyword()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc false
  @spec lookup(String.t()) :: {:ok, boolean()} | {:error, :not_running}
  def lookup(domain) when is_binary(domain) do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        if owns_metadata_table?(pid), do: lookup_active(domain, pid, 3), else: {:error, :not_running}

      nil ->
        {:error, :not_running}
    end
  end

  @doc false
  @spec reload() :: :ok | {:error, term()}
  def reload do
    call(:reload)
  end

  @doc false
  @spec load_url(String.t()) :: :ok | {:error, term()}
  def load_url(url) when is_binary(url) do
    call({:load_url, url})
  end

  def load_url(_url), do: {:error, :invalid_url}

  @doc false
  @spec replace(MapSet.t()) :: :ok | {:error, term()}
  def replace(domains) do
    call({:replace, domains})
  end

  @impl true
  def init(opts) do
    source = Keyword.get(opts, :source, Disposable.Source.configured_source())
    url_options = Keyword.get(opts, :url_options, Disposable.Source.configured_url_options())
    source_options = opts |> Keyword.delete(:source) |> Keyword.put(:url_options, url_options)

    with {:ok, domains} <- Disposable.Source.load(source, source_options),
         :ok <- Disposable.Source.validate_domains(domains),
         {:ok, metadata_table} <- create_metadata_table(),
         {:ok, active_table} <- create_domain_table(domains),
         :ok <- publish(metadata_table, active_table) do
      {:ok,
       %{
         metadata_table: metadata_table,
         active_table: active_table,
         source: source,
         url_options: url_options
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    source = Disposable.Source.configured_source()
    url_options = Disposable.Source.configured_url_options()

    case Disposable.Source.load(source, url_options: url_options) do
      {:ok, domains} -> replace_and_reply(domains, state, source, url_options)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:load_url, url}, _from, state) do
    url_options = Disposable.Source.configured_url_options()

    case Disposable.Source.load({:url, url}, url_options: url_options) do
      {:ok, domains} -> replace_and_reply(domains, state, state.source, url_options)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:replace, domains}, _from, state) do
    case Disposable.Source.validate_domains(domains) do
      :ok -> replace_and_reply(domains, state, state.source, state.url_options)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp replace_and_reply(domains, state, source, url_options) do
    case replace_active_table(domains, state) do
      {:ok, state} -> {:reply, :ok, %{state | source: source, url_options: url_options}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp replace_active_table(domains, state) do
    case create_domain_table(domains) do
      {:ok, new_table} ->
        case publish(state.metadata_table, new_table) do
          :ok ->
            _ = safe_delete_table(state.active_table)
            {:ok, %{state | active_table: new_table}}

          {:error, reason} ->
            _ = safe_delete_table(new_table)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_metadata_table do
    try do
      {:ok, :ets.new(@metadata_table, [:named_table, :set, :protected, read_concurrency: true])}
    rescue
      ArgumentError -> {:error, :not_running}
    end
  end

  defp create_domain_table(domains) do
    table = :ets.new(:disposable_domains_generation, [:set, :protected, read_concurrency: true])

    try do
      true = :ets.insert(table, Enum.map(domains, &{&1, true}))
      {:ok, table}
    rescue
      ArgumentError ->
        _ = safe_delete_table(table)
        {:error, {:store_error, :invalid_table}}
    catch
      :error, reason ->
        _ = safe_delete_table(table)
        {:error, {:store_error, reason}}
    end
  end

  defp publish(metadata_table, active_table) do
    true = :ets.insert(metadata_table, {:active, active_table})
    :ok
  rescue
    ArgumentError -> {:error, :not_running}
  end

  defp safe_delete_table(table) do
    try do
      :ets.delete(table)
    catch
      :error, :badarg -> :ok
    end
  end

  defp owns_metadata_table?(pid) do
    :ets.info(@metadata_table, :owner) == pid
  catch
    :error, :badarg -> false
  end

  defp lookup_active(domain, pid, attempts) do
    case :ets.lookup(@metadata_table, :active) do
      [{:active, table}] ->
        case safe_member?(table, domain) do
          {:ok, result} -> {:ok, result}
          :retry when attempts > 1 -> lookup_active(domain, pid, attempts - 1)
          :retry -> if Process.alive?(pid), do: {:error, :not_running}, else: {:error, :not_running}
        end

      [] ->
        if Process.alive?(pid), do: {:error, :not_running}, else: {:error, :not_running}
    end
  catch
    :error, :badarg ->
      if attempts > 1 and Process.alive?(pid) do
        lookup_active(domain, pid, attempts - 1)
      else
        {:error, :not_running}
      end
  end

  defp safe_member?(table, domain) do
    try do
      {:ok, :ets.member(table, domain)}
    rescue
      ArgumentError -> :retry
    catch
      :error, :badarg -> :retry
    end
  end

  defp call(message) do
    GenServer.call(@name, message, @call_timeout)
  catch
    :exit, _reason -> {:error, :not_running}
  end
end
