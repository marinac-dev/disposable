defmodule Disposable do
  @moduledoc """
  Checks whether an email address uses a disposable domain.

  Email handling is intentionally limited validation: the value must be a
  printable UTF-8 string with one non-empty local part and a valid ASCII domain.
  This module does not implement complete RFC 5322 parsing.
  """

  @typedoc "An email address represented as a UTF-8 string."
  @type email :: String.t()
  @typedoc "A disposable domain name represented as a UTF-8 string."
  @type domain :: String.t()

  @doc "Starts the ETS-backed domain store registered as `Disposable`."
  @deprecated "the application starts the store automatically"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Disposable.Store.start_link(opts)
  end

  @doc false
  def child_spec(opts) do
    Disposable.Store.child_spec(opts)
    |> Map.put(:id, __MODULE__)
    |> Map.put(:start, {__MODULE__, :start_link, [opts]})
  end

  @doc """
  Looks up an email address without collapsing errors.

  Returns `{:ok, boolean()}` for valid input, or `{:error, reason}` for
  `:invalid_email` and `:not_running`.
  """
  @spec lookup(term()) :: {:ok, boolean()} | {:error, :invalid_email | :not_running}
  def lookup(email) do
    with {:ok, domain} <- extract_domain(email),
         {:ok, result} <- Disposable.Store.lookup(domain) do
      {:ok, result}
    else
      :error -> {:error, :invalid_email}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns `true` only for a valid email whose exact domain is listed."
  @spec disposable?(term()) :: boolean()
  def disposable?(email) do
    match?({:ok, true}, lookup(email))
  end

  @deprecated "use disposable?/1 instead"
  @doc "Compatibility alias for `disposable?/1`; invalid and unavailable lookups return `false`."
  @spec check(term()) :: boolean()
  def check(email), do: disposable?(email)

  @doc "Reloads the configured source, preserving the active generation on failure."
  @deprecated "use the configured source and an administrator-controlled refresh operation"
  @spec reload() :: :ok | {:error, term()}
  def reload, do: Disposable.Store.reload()

  @doc """
  Loads a newline-delimited domain list from an administrator-controlled URL.

  Redirects, non-200 responses, invalid content, and transport failures leave
  the active generation unchanged.
  """
  @spec load_url(String.t()) :: :ok | {:error, term()}
  def load_url(url), do: Disposable.Store.load_url(url)

  @doc false
  @spec extract_domain(term()) :: {:ok, domain()} | :error
  def extract_domain(email) when is_binary(email) do
    if String.valid?(email) and String.printable?(email) and not Regex.match?(~r/\s/u, email) do
      case String.split(email, "@") do
        [local_part, domain] when local_part != "" and domain != "" ->
          domain = String.downcase(domain)

          if String.trim(local_part) == local_part and String.trim(domain) == domain and
               Disposable.Source.valid_domain?(domain) do
            {:ok, domain}
          else
            :error
          end

        _invalid ->
          :error
      end
    else
      :error
    end
  end

  def extract_domain(_email), do: :error
end
