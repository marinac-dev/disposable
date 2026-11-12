defmodule Disposable.Store do
  @moduledoc """
  Owns the active domain generation and serializes source replacements.

  The named ETS metadata table holds the active table identifier and the
  store status. Domain and status reads use that table directly and never call
  this GenServer, so both keep working while a slow refresh is in progress.

  ## Lifecycle

  The store is a small state machine. Its status row is the single source of
  truth for the current state and is written only by the transitions below,
  always in the same atomic insert as the active table identifier.

  | From          | Event                        | To            | Effect                                    |
  | ------------- | ---------------------------- | ------------- | ----------------------------------------- |
  | not running   | start, source loads          | `:ready`      | generation 1 published                    |
  | not running   | start, source fails          | not running   | process stops with the reason             |
  | `:ready`      | `reload/0` or `load_url/1`   | `:refreshing` | lookups keep using the active generation  |
  | `:refreshing` | new generation published     | `:ready`      | generation + 1, `last_error` cleared      |
  | `:refreshing` | load or validation fails     | `:ready`      | generation unchanged, `last_error` set    |
  | any           | process exits                | not running   | tables are deleted with their owner       |

  Callers observe "not running" as `{:error, :not_running}`.
  """

  use GenServer

  @name Disposable

  # The status before the first generation is published. It is never visible to
  # callers: the metadata table does not exist until that publication succeeds.
  @unloaded %{state: :ready, generation: 0, domain_count: 0, source: nil, loaded_at: nil, last_error: nil}
  @metadata_table :disposable_domains
  @call_timeout 60_000

  @typedoc """
  A snapshot of the store lifecycle.

    * `:state` - `:ready`, or `:refreshing` while a replacement is loading
    * `:generation` - starts at 1 and increases with every published replacement
    * `:domain_count` - number of domains in the active generation
    * `:source` - where the active generation came from; URLs are reported
      without credentials, query, or fragment, and `:manual` marks a direct
      replacement
    * `:loaded_at` - when the active generation was published
    * `:last_error` - the most recent failed refresh since `:loaded_at`, or `nil`
  """
  @type status :: %{
          state: :ready | :refreshing,
          generation: pos_integer(),
          domain_count: non_neg_integer(),
          source: term(),
          loaded_at: DateTime.t(),
          last_error: nil | %{at: DateTime.t(), source: term(), reason: term()}
        }

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
  @spec status() :: {:ok, status()} | {:error, :not_running}
  def status do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        if owns_metadata_table?(pid), do: read_status(), else: {:error, :not_running}

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
         :ok <- publish(metadata_table, active_table, committed(@unloaded, source, active_table)) do
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

    refresh(state, source, url_options, source)
  end

  @impl true
  def handle_call({:load_url, url}, _from, state) do
    url_options = Disposable.Source.configured_url_options()

    refresh(state, {:url, url}, url_options, state.source)
  end

  @impl true
  def handle_call({:replace, domains}, _from, state) do
    previous = current_status(state.metadata_table)

    with :ok <- Disposable.Source.validate_domains(domains),
         {:ok, new_state} <- replace_active_table(domains, state, :manual, previous) do
      {:reply, :ok, new_state}
    else
      {:error, reason} -> abort(state, previous, :manual, reason)
    end
  end

  # ready -> refreshing -> ready. The active generation serves lookups for the
  # whole refresh and is only swapped out by a successful publication.
  defp refresh(state, source, url_options, configured_source) do
    previous = current_status(state.metadata_table)
    put_status(state.metadata_table, %{previous | state: :refreshing})

    with {:ok, domains} <- Disposable.Source.load(source, url_options: url_options),
         {:ok, new_state} <- replace_active_table(domains, state, source, previous) do
      {:reply, :ok, %{new_state | source: configured_source, url_options: url_options}}
    else
      {:error, reason} -> abort(state, previous, source, reason)
    end
  end

  defp abort(state, previous, source, reason) do
    put_status(state.metadata_table, aborted(previous, source, reason))
    {:reply, {:error, reason}, state}
  end

  defp replace_active_table(domains, state, source, previous) do
    case create_domain_table(domains) do
      {:ok, new_table} ->
        case publish(state.metadata_table, new_table, committed(previous, source, new_table)) do
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

  defp committed(previous, source, table) do
    %{
      state: :ready,
      generation: previous.generation + 1,
      domain_count: :ets.info(table, :size),
      source: describe_source(source),
      loaded_at: DateTime.utc_now(),
      last_error: nil
    }
  end

  defp aborted(previous, source, reason) do
    %{previous | state: :ready, last_error: %{at: DateTime.utc_now(), source: describe_source(source), reason: reason}}
  end

  # URLs may carry credentials or signed query strings; keep them out of status.
  defp describe_source({:url, url}) when is_binary(url) do
    {:url, URI.to_string(%{URI.parse(url) | userinfo: nil, query: nil, fragment: nil})}
  rescue
    _error -> {:url, :invalid}
  end

  defp describe_source(source), do: source

  defp current_status(metadata_table) do
    case :ets.lookup(metadata_table, :status) do
      [{:status, status}] -> status
      [] -> @unloaded
    end
  rescue
    ArgumentError -> @unloaded
  end

  defp put_status(metadata_table, status) do
    true = :ets.insert(metadata_table, {:status, status})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp read_status do
    case :ets.lookup(@metadata_table, :status) do
      [{:status, status}] -> {:ok, status}
      [] -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
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

  # A list insert is atomic, so readers never see a generation paired with the
  # status of another one.
  defp publish(metadata_table, active_table, status) do
    true = :ets.insert(metadata_table, [{:active, active_table}, {:status, status}])
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
          :retry -> {:error, :not_running}
        end

      [] ->
        {:error, :not_running}
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
