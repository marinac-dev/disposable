defmodule DisposableIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @max_response_bytes 5 * 1024 * 1024

  setup do
    _store = Process.whereis(Disposable) || start_supervised!(Disposable)
    original_domains_file = Application.get_env(:disposable, :disposable_domains_file)
    original_source = Application.get_env(:disposable, :source)
    original_url_options = Application.get_env(:disposable, :url_options)

    on_exit(fn ->
      restore_domains_file(original_domains_file)
      restore_env(:source, original_source)
      restore_env(:url_options, original_url_options)
      if Process.whereis(Disposable), do: apply(Disposable, :reload, [])
    end)

    :ok
  end

  test "load_url/1 loads and normalizes a domain list" do
    url = start_http_server(200, "ALLTEMPMAIL.COM\nExample.ORG\n\n# ignored\n")

    assert :ok = Disposable.load_url(url)
    assert Disposable.disposable?("user@alltempmail.com")
    assert Disposable.disposable?("user@example.org")
    refute Disposable.disposable?("user@missing.example")
  end

  test "load_url/1 keeps the current list for failed responses" do
    url = start_http_server(503, "temporarily unavailable\n")

    assert Disposable.disposable?("user@alltempmail.com")
    assert {:error, {:http_status, 503}} = Disposable.load_url(url)
    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "load_url/1 rejects invalid and empty sources" do
    assert {:error, :invalid_url} = Disposable.load_url("not a URL")
    assert {:error, :invalid_url} = Disposable.load_url(nil)

    url = start_http_server(200, "\n# no domains\n")
    assert {:error, :empty_domain_list} = Disposable.load_url(url)
    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "load_url/1 rejects partial and redirect responses without following them" do
    partial_url = start_http_server(206, "partial")
    redirect_url = start_http_server(302, "redirect", headers: [{"Location", "https://example.invalid/domains.txt"}])

    assert {:error, {:http_status, 206}} = Disposable.load_url(partial_url)
    assert {:error, {:http_status, 302}} = Disposable.load_url(redirect_url)
    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "load_url/1 rejects malformed non-empty sources" do
    url = start_http_server(200, "<html>not a domain list</html>\n")

    assert {:error, {:invalid_domain, %{line: 1, domain: "<html>not a domain list</html>"}}} =
             Disposable.load_url(url)

    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "Http.get/3 returns status, headers, and body from a local server" do
    url = start_http_server(200, "response body")

    assert {:ok, 200, headers, "response body"} = Disposable.Http.fetch(url, [{"x-test", "value"}])
    assert headers["content-type"] == "text/plain"
  end

  test "deprecated Http.get/3 preserves successful responses" do
    url = start_http_server(200, "response body")

    assert {:ok, 200, _headers, "response body"} = apply(Disposable.Http, :get, [url])
  end

  test "Http.fetch preserves unrelated mailbox messages" do
    url = start_http_server(200, "response body")
    send(self(), :unrelated_http_message)

    assert {:ok, 200, _headers, "response body"} = Disposable.Http.fetch(url)
    assert_receive :unrelated_http_message
  end

  test "load_url/1 preserves concurrent Store calls" do
    url = start_http_server(200, "remote.test\n", notify: self(), response_delay: 100)

    load_task = Task.async(fn -> Disposable.load_url(url) end)
    assert_receive :http_request_received, 1_000

    replace_task = Task.async(fn -> Disposable.Store.replace(MapSet.new(["replacement.test"])) end)

    assert :ok = Task.await(load_task, 2_000)

    try do
      assert {:ok, :ok} = Task.yield(replace_task, 1_000)
    after
      Task.shutdown(replace_task, :brutal_kill)
    end

    assert Disposable.disposable?("user@replacement.test")
  end

  test "Http.fetch consumes response trailers while streaming" do
    url = start_http_server(200, "response body", chunked: true)

    assert {:ok, 200, _headers, "response body"} = Disposable.Http.fetch(url)
  end

  test "Http.fetch returns a transport error for truncated streamed bodies" do
    body = "response body"
    url = start_http_server(200, body, content_length: byte_size(body) + 1)

    assert {:error, {:transport, _reason}} = Disposable.Http.fetch(url)
  end

  test "Http.fetch keeps an explicit Accept-Encoding header" do
    url = start_http_server(200, "response body")

    assert {:ok, 200, _headers, "response body"} =
             Disposable.Http.fetch(url, [{"Accept-Encoding", "gzip"}])
  end

  test "Http.get/3 rejects a response larger than the declared limit" do
    url = start_http_server(200, "", content_length: @max_response_bytes + 1)

    assert {:error, :response_too_large} = Disposable.Http.fetch(url)
  end

  test "Http.get/3 times out when the server does not respond" do
    url = start_http_server(200, "", send_response: false)

    assert {:error, {:transport, :timeout}} = Disposable.Http.fetch(url, [], 50)
  end

  test "deprecated Http.get/3 preserves its timeout return shape" do
    url = start_http_server(200, "", send_response: false)

    assert {:error, :timeout} = apply(Disposable.Http, :get, [url, [], 50])
  end

  test "Http.get/3 streams responses without a content length" do
    url = start_http_server(200, "response body", content_length: nil)

    assert {:ok, 200, _headers, "response body"} = Disposable.Http.fetch(url)
  end

  test "Http.get/3 accepts a non-numeric content length" do
    url = start_http_server(200, "response body", content_length: "unknown")

    assert {:error, {:transport, :invalid_content_length}} = Disposable.Http.fetch(url)
  end

  test "Http.get/3 times out while streaming an incomplete response" do
    url = start_http_server(200, "response body", send_headers_only: true)

    assert {:error, {:transport, :timeout}} = Disposable.Http.fetch(url, [], 50)
  end

  test "Http.get/3 returns a transport error when the server closes without responding" do
    url = start_http_server(200, "", send_response: false, close_socket: true)

    assert {:error, {:transport, _reason}} = Disposable.Http.fetch(url)
  end

  test "Http.get/3 rejects an oversized streamed response" do
    body = String.duplicate("x", @max_response_bytes + 1)
    url = start_http_server(200, body, content_length: nil)

    assert {:error, :response_too_large} = Disposable.Http.fetch(url)
  end

  test "Http.fetch/3 enforces the exact configured byte boundary" do
    exact_url = start_http_server(200, "1234")
    oversized_url = start_http_server(200, "1234")

    assert {:ok, 200, _headers, "1234"} = Disposable.Http.fetch(exact_url, [], max_body_bytes: 4)
    assert {:error, :response_too_large} = Disposable.Http.fetch(oversized_url, [], max_body_bytes: 3)
  end

  test "Http.fetch/3 returns raw encoded bytes" do
    url = start_http_server(200, "raw body", headers: [{"Content-Encoding", "gzip"}])

    assert {:ok, 200, headers, "raw body"} = Disposable.Http.fetch(url)
    assert headers["content-encoding"] == "gzip"
  end

  test "load_url/1 rejects invalid UTF-8 response bodies" do
    url = start_http_server(200, <<255>>)

    assert {:error, :invalid_encoding} = Disposable.load_url(url)
    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "Http.get/3 preserves the actual status for content-range responses" do
    url = start_http_server(200, "part", headers: [{"Content-Range", "bytes 0-3/10"}])

    assert {:ok, 200, _headers, "part"} = Disposable.Http.fetch(url)
  end

  defp restore_domains_file(nil), do: Application.delete_env(:disposable, :disposable_domains_file)

  defp restore_domains_file(path),
    do: Application.put_env(:disposable, :disposable_domains_file, path)

  defp restore_env(key, nil), do: Application.delete_env(:disposable, key)
  defp restore_env(key, value), do: Application.put_env(:disposable, key, value)

  defp start_http_server(status, body, options \\ []) do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {address, port}} = :inet.sockname(listener)

    reason = if status == 200, do: "OK", else: "Error"

    chunked = Keyword.get(options, :chunked, false)

    content_length =
      if chunked do
        []
      else
        case Keyword.fetch(options, :content_length) do
          {:ok, value} when is_binary(value) -> ["Content-Length: ", value, "\r\n"]
          {:ok, nil} -> []
          {:ok, value} -> ["Content-Length: ", Integer.to_string(value), "\r\n"]
          :error -> ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n"]
        end
      end

    transfer_encoding = if chunked, do: "Transfer-Encoding: chunked\r\n", else: ""
    trailer = if chunked, do: "Trailer: X-Stream-Trailer\r\n", else: ""

    headers =
      options
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {key, value} -> [key, ": ", value, "\r\n"] end)

    response_body =
      cond do
        Keyword.get(options, :send_headers_only, false) ->
          ""

        chunked ->
          [
            Integer.to_string(byte_size(body), 16),
            "\r\n",
            body,
            "\r\n0\r\nX-Stream-Trailer: trailer\r\n\r\n"
          ]

        true ->
          body
      end

    response =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason,
        "\r\nContent-Type: text/plain\r\n",
        content_length,
        transfer_encoding,
        trailer,
        headers,
        "Connection: close\r\n\r\n",
        response_body
      ]
      |> IO.iodata_to_binary()

    server =
      spawn(fn ->
        try do
          with {:ok, socket} <- :gen_tcp.accept(listener),
               {:ok, _request} <- :gen_tcp.recv(socket, 0, 5_000) do
            if Keyword.get(options, :notify, false), do: send(owner, :http_request_received)
            Process.sleep(Keyword.get(options, :response_delay, 0))

            if Keyword.get(options, :send_response, true) do
              :gen_tcp.send(socket, response)

              if Keyword.get(options, :send_headers_only, false) do
                receive do
                  :close -> :gen_tcp.close(socket)
                end
              else
                :gen_tcp.close(socket)
              end
            else
              if Keyword.get(options, :close_socket, false) do
                :gen_tcp.close(socket)
              else
                receive do
                  :close -> :gen_tcp.close(socket)
                end
              end
            end
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    host = address |> :inet.ntoa() |> List.to_string()
    "http://#{host}:#{port}"
  end
end
