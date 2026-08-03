defmodule Disposable.Source do
  @moduledoc """
  Loads and validates disposable-domain sources.

  Source files are UTF-8, newline-delimited, ASCII domain lists. Punycode labels
  are accepted, but Unicode domain labels are intentionally not normalized.
  """

  @default_max_source_bytes 5 * 1024 * 1024
  @default_max_line_bytes 4 * 1024
  @default_max_domain_count 1_000_000
  @max_domain_length 253

  @domain_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/i

  @type source :: :bundled | {:file, String.t()} | {:url, String.t()}
  @type limits :: [
          max_source_bytes: pos_integer(),
          max_line_bytes: pos_integer(),
          max_domain_count: pos_integer()
        ]

  @doc "Returns the configured source, including the deprecated file setting."
  @spec configured_source() :: term()
  def configured_source do
    case Application.fetch_env(:disposable, :source) do
      {:ok, source} -> source
      :error -> legacy_configured_source()
    end
  end

  @doc "Returns the configured URL-loading options."
  @spec configured_url_options() :: keyword()
  def configured_url_options do
    Application.get_env(:disposable, :url_options, [])
  end

  @doc "Loads and parses a configured source."
  @spec load(term(), keyword()) :: {:ok, MapSet.t()} | {:error, term()}
  def load(source, opts \\ []) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) -> {:error, :invalid_source}
      source == :bundled -> load_file(Application.app_dir(:disposable, "priv/domains.txt"), opts)
      match?({:file, _}, source) -> load_explicit_file(source, opts)
      match?({:url, _}, source) -> load_url(source, opts)
      true -> {:error, :invalid_source}
    end
  end

  @doc "Parses a UTF-8 newline-delimited domain list."
  @spec parse(binary(), keyword()) :: {:ok, MapSet.t()} | {:error, term()}
  def parse(contents, opts \\ [])

  def parse(contents, opts) when is_binary(contents) and is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, limits} <- normalize_limits(opts),
           :ok <- validate_encoding(contents),
           :ok <- validate_source_size(contents, limits.max_source_bytes) do
        contents
        |> String.split("\n", trim: false)
        |> Enum.with_index(1)
        |> parse_lines(limits, MapSet.new())
      end
    else
      {:error, :invalid_source}
    end
  end

  def parse(_contents, _opts), do: {:error, :invalid_encoding}

  @doc "Validates one ASCII domain using exact-domain matching rules."
  @spec valid_domain?(term()) :: boolean()
  def valid_domain?(domain) when is_binary(domain) do
    String.valid?(domain) and byte_size(domain) <= @max_domain_length and Regex.match?(@domain_pattern, domain)
  end

  def valid_domain?(_domain), do: false

  @doc "Validates a parsed domain set before publication."
  @spec validate_domains(term()) :: :ok | {:error, term()}
  def validate_domains(%MapSet{} = domains) do
    cond do
      MapSet.size(domains) == 0 -> {:error, :empty_domain_list}
      Enum.all?(domains, &valid_domain?/1) -> :ok
      true -> {:error, :invalid_domain}
    end
  end

  def validate_domains(_domains), do: {:error, :invalid_domain_list}

  @doc false
  @spec default_limits() :: limits()
  def default_limits do
    [
      max_source_bytes: @default_max_source_bytes,
      max_line_bytes: @default_max_line_bytes,
      max_domain_count: @default_max_domain_count
    ]
  end

  defp legacy_configured_source do
    case Application.get_env(:disposable, :disposable_domains_file) do
      nil -> :bundled
      path -> {:file, path}
    end
  end

  defp load_explicit_file({:file, path}, opts) when is_binary(path) and path != "" do
    if String.valid?(path), do: load_file(path, opts), else: {:error, :invalid_source}
  end

  defp load_explicit_file(_source, _opts), do: {:error, :invalid_source}

  defp load_url({:url, url}, opts) when is_binary(url) and url != "" do
    url_options = Keyword.get(opts, :url_options, configured_url_options())

    with {:ok, url_options} <- validate_url_options(url_options),
         {:ok, status, _headers, body} <- Disposable.Http.fetch(url, [], url_options),
         :ok <- validate_status(status),
         parse_opts = parser_options_from(Keyword.merge(opts, url_options)),
         {:ok, domains} <- parse(body, parse_opts),
         :ok <- validate_domains(domains) do
      {:ok, domains}
    end
  end

  defp load_url(_source, _opts), do: {:error, :invalid_url}

  defp load_file(path, opts) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case parse(contents, parser_options_from(opts)) do
          {:ok, domains} ->
            case validate_domains(domains) do
              :ok -> {:ok, domains}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, {:file_error, path, reason}}
        end

      {:error, reason} ->
        {:error, {:file_error, path, reason}}
    end
  end

  defp load_file(_path, _opts), do: {:error, :invalid_source}

  defp validate_status(200), do: :ok
  defp validate_status(status), do: {:error, {:http_status, status}}

  defp validate_url_options(options) when is_list(options) do
    if Keyword.keyword?(options), do: {:ok, options}, else: {:error, :invalid_source}
  end

  defp validate_url_options(_options), do: {:error, :invalid_source}

  defp parser_options_from(options) do
    options
    |> Keyword.take([:max_source_bytes, :max_line_bytes, :max_domain_count])
    |> maybe_source_limit(options)
  end

  defp maybe_source_limit(parser_options, options) do
    if Keyword.has_key?(parser_options, :max_source_bytes) do
      parser_options
    else
      case Keyword.get(options, :max_body_bytes) do
        nil -> parser_options
        max_body_bytes -> Keyword.put(parser_options, :max_source_bytes, max_body_bytes)
      end
    end
  end

  defp normalize_limits(opts) do
    defaults = Map.new(default_limits())

    with {:ok, max_source_bytes} <- positive_limit(opts, defaults.max_source_bytes, :max_source_bytes),
         {:ok, max_line_bytes} <- positive_limit(opts, defaults.max_line_bytes, :max_line_bytes),
         {:ok, max_domain_count} <- positive_limit(opts, defaults.max_domain_count, :max_domain_count) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_line_bytes: max_line_bytes,
         max_domain_count: max_domain_count
       }}
    end
  end

  defp positive_limit(opts, default, key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, :invalid_source}
    end
  end

  defp validate_source_size(contents, max_source_bytes) do
    if byte_size(contents) <= max_source_bytes do
      :ok
    else
      {:error, {:source_too_large, max_source_bytes}}
    end
  end

  defp validate_encoding(contents) do
    if String.valid?(contents), do: :ok, else: {:error, :invalid_encoding}
  end

  defp parse_lines([], _limits, domains) do
    case validate_domains(domains) do
      :ok -> {:ok, domains}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_lines([{raw_line, line_number} | rest], limits, domains) do
    line = remove_crlf_marker(raw_line)

    cond do
      byte_size(line) > limits.max_line_bytes ->
        {:error, {:line_too_long, %{line: line_number, max_bytes: limits.max_line_bytes}}}

      true ->
        case normalize_line(line) do
          :skip -> parse_lines(rest, limits, domains)
          {:ok, domain} -> add_domain(rest, line_number, domain, limits, domains)
          {:error, reason} -> {:error, {:invalid_domain, %{line: line_number, domain: reason}}}
        end
    end
  end

  defp add_domain(rest, line_number, domain, limits, domains) do
    if MapSet.member?(domains, domain) do
      parse_lines(rest, limits, domains)
    else
      domains = MapSet.put(domains, domain)

      if MapSet.size(domains) > limits.max_domain_count do
        {:error, {:domain_count_exceeded, %{line: line_number, max: limits.max_domain_count}}}
      else
        parse_lines(rest, limits, domains)
      end
    end
  end

  defp remove_crlf_marker(line) do
    if String.ends_with?(line, "\r") do
      binary_part(line, 0, byte_size(line) - 1)
    else
      line
    end
  end

  defp normalize_line(line) do
    domain = String.trim(line)

    cond do
      domain == "" or String.starts_with?(domain, "#") -> :skip
      valid_domain?(String.downcase(domain)) -> {:ok, String.downcase(domain)}
      true -> {:error, String.downcase(domain)}
    end
  end
end
