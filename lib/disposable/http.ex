defmodule Disposable.Http do
  @default_timeout 15_000

  def get(url, headers \\ [], timeout \\ @default_timeout) do
    request_headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    opts = [
      timeout: timeout,
      ssl: [verify: :verify_none],
      autoredirect: false
    ]

    case :httpc.request(:get, {String.to_charlist(url), request_headers}, opts, []) do
      {:ok, {{_version, status_code, _reason}, response_headers, body}} ->
        headers_map = Enum.into(response_headers, %{}, fn {k, v} -> {List.to_string(k), List.to_string(v)} end)

        {:ok, status_code, headers_map, body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
