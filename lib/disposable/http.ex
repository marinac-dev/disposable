defmodule Disposable.Http do
  @moduledoc """
  Deprecated compatibility wrapper around Req.

  Requests do not follow redirects, retry, decompress, or decode response
  bodies. Response bytes are bounded while Req streams them to the caller.
  """

  @default_timeout 15_000
  @default_max_body_bytes 5 * 1024 * 1024

  @type response :: {:ok, non_neg_integer(), map(), binary()}
  @type result :: response() | {:error, term()}

  @doc """
  Performs a bounded GET request.

  The third argument remains a timeout integer for compatibility. It also
  accepts the `Disposable` URL options keyword list.
  """
  @deprecated "use Disposable.load_url/1 for domain sources"
  @spec get(String.t(), [{String.t(), String.t()}], pos_integer() | keyword()) :: result()
  def get(url, headers \\ [], timeout_or_options \\ @default_timeout) do
    fetch(url, headers, timeout_or_options)
    |> legacy_result()
  end

  @doc false
  @spec fetch(String.t(), [{String.t(), String.t()}], pos_integer() | keyword()) :: result()
  def fetch(url, headers \\ [], timeout_or_options \\ @default_timeout) do
    with :ok <- validate_url(url),
         {:ok, options} <- normalize_options(timeout_or_options),
         {:ok, request_headers} <- normalize_headers(headers) do
      isolated_request(url, request_headers, options)
    end
  end

  defp legacy_result({:error, {:transport, :timeout}}), do: {:error, :timeout}
  defp legacy_result(result), do: result

  defp isolated_request(url, headers, options) do
    caller = self()
    result_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {result_ref, request(url, headers, options)})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        {:error, {:transport, sanitize_reason(reason)}}
    end
  end

  defp request(url, headers, options) do
    deadline = System.monotonic_time(:millisecond) + options.request_timeout

    request_options = [
      headers: request_headers_with_identity(headers),
      redirect: false,
      retry: false,
      raw: true,
      decode_body: false,
      decoders: false,
      compressed: false,
      connect_options: [timeout: options.connect_timeout, protocols: [:http1]],
      receive_timeout: options.receive_timeout,
      request_timeout: options.request_timeout,
      into: :self
    ]

    result =
      try do
        Req.get(url, request_options)
      rescue
        error -> {:error, {:transport, exception_reason(error)}}
      catch
        :exit, reason -> {:error, {:transport, sanitize_reason(reason)}}
      end

    case result do
      {:ok, %Req.Response{} = response} -> stream_response(response, options.max_body_bytes, deadline)
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp stream_response(response, max_body_bytes, deadline) do
    case validate_content_length(response) do
      {:ok, declared_size} when declared_size > max_body_bytes ->
        cancel_response(response)
        {:error, :response_too_large}

      {:ok, _declared_size} ->
        receive_response(response, [], 0, max_body_bytes, deadline)

      {:error, reason} ->
        cancel_response(response)
        {:error, reason}
    end
  end

  defp receive_response(response, chunks, size, max_body_bytes, deadline) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, events} ->
            handle_events(events, response, chunks, size, max_body_bytes, deadline)

          :unknown ->
            receive_response(response, chunks, size, max_body_bytes, deadline)

          {:error, reason} ->
            cancel_response(response)
            {:error, normalize_error(reason)}
        end
    after
      remaining_timeout(deadline) ->
        cancel_response(response)
        {:error, {:transport, :timeout}}
    end
  end

  defp handle_events([], response, chunks, size, max_body_bytes, deadline) do
    receive_response(response, chunks, size, max_body_bytes, deadline)
  end

  defp handle_events([{:data, data} | rest], response, chunks, size, max_body_bytes, deadline) do
    new_size = size + byte_size(data)

    if new_size > max_body_bytes do
      cancel_response(response)
      {:error, :response_too_large}
    else
      handle_events(rest, response, [data | chunks], new_size, max_body_bytes, deadline)
    end
  end

  defp handle_events([:done | _rest], response, chunks, _size, _max_body_bytes, _deadline) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, response.status, headers_to_map(response.headers), body}
  end

  defp handle_events([{:trailers, _trailers} | rest], response, chunks, size, max_body_bytes, deadline) do
    handle_events(rest, response, chunks, size, max_body_bytes, deadline)
  end

  defp handle_events([_event | rest], response, chunks, size, max_body_bytes, deadline) do
    handle_events(rest, response, chunks, size, max_body_bytes, deadline)
  end

  defp validate_content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        {:ok, 0}

      [value | _rest] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _invalid -> {:error, :invalid_response}
        end
    end
  end

  defp headers_to_map(headers) do
    Enum.into(headers, %{}, fn {key, values} ->
      value = values |> List.wrap() |> List.first() || ""
      {key, value}
    end)
  end

  defp cancel_response(response) do
    _ = Req.cancel_async_response(response)
    :ok
  rescue
    _error -> :ok
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp normalize_error(%Req.TransportError{reason: reason}), do: {:transport, sanitize_reason(reason)}
  defp normalize_error(%Req.HTTPError{reason: reason}), do: {:transport, sanitize_reason(reason)}
  defp normalize_error(%Req.TooManyRedirectsError{}), do: {:transport, :redirect}
  defp normalize_error({:transport, reason}), do: {:transport, sanitize_reason(reason)}
  defp normalize_error(reason), do: {:transport, sanitize_reason(reason)}

  defp exception_reason(%{__struct__: module, reason: reason}), do: {module, sanitize_reason(reason)}
  defp exception_reason(%{__struct__: module}), do: module
  defp exception_reason(exception), do: sanitize_reason(exception)

  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(reason) when is_binary(reason), do: :request_failed
  defp sanitize_reason({:invalid_content_length_header, _value}), do: :invalid_content_length
  defp sanitize_reason({module, value}) when is_atom(module), do: {module, sanitize_reason(value)}
  defp sanitize_reason(_reason), do: :request_failed

  defp validate_url(url) when is_binary(url) do
    if String.valid?(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          :ok

        _invalid ->
          {:error, :invalid_url}
      end
    else
      {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp validate_url(_url), do: {:error, :invalid_url}

  defp normalize_options(timeout) when is_integer(timeout) do
    normalize_options(timeout: timeout)
  end

  defp normalize_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      timeout = Keyword.get(options, :timeout, @default_timeout)
      max_body_bytes = Keyword.get(options, :max_body_bytes, @default_max_body_bytes)
      connect_timeout = Keyword.get(options, :connect_timeout, timeout)
      receive_timeout = Keyword.get(options, :receive_timeout, timeout)
      request_timeout = Keyword.get(options, :request_timeout, timeout)

      if positive_integer?(timeout) and positive_integer?(max_body_bytes) and
           positive_integer?(connect_timeout) and positive_integer?(receive_timeout) and
           positive_integer?(request_timeout) do
        {:ok,
         %{
           max_body_bytes: max_body_bytes,
           connect_timeout: connect_timeout,
           receive_timeout: receive_timeout,
           request_timeout: request_timeout
         }}
      else
        {:error, :invalid_timeout}
      end
    else
      {:error, :invalid_timeout}
    end
  end

  defp normalize_options(_options), do: {:error, :invalid_timeout}

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {key, value}, {:ok, normalized} when is_binary(key) and is_binary(value) ->
        if valid_header_name?(key) and valid_header_value?(value) do
          {:cont, {:ok, [{String.downcase(key), value} | normalized]}}
        else
          {:halt, {:error, :invalid_headers}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_headers}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_headers(_headers), do: {:error, :invalid_headers}

  defp request_headers_with_identity(headers) do
    if Enum.any?(headers, fn {key, _value} -> key == "accept-encoding" end) do
      headers
    else
      [{"accept-encoding", "identity"} | headers]
    end
  end

  defp valid_header_name?(name) do
    String.valid?(name) and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name)
  end

  defp valid_header_value?(value) do
    String.valid?(value) and not String.contains?(value, ["\r", "\n"]) and
      value |> :binary.bin_to_list() |> Enum.all?(fn byte -> byte == 9 or byte in 32..126 end)
  end
end
