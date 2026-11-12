defmodule DisposableTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  doctest Disposable

  setup do
    _store = Process.whereis(Disposable) || start_supervised!(Disposable)

    original_domains_file = Application.get_env(:disposable, :disposable_domains_file)
    original_source = Application.get_env(:disposable, :source)
    original_url_options = Application.get_env(:disposable, :url_options)

    on_exit(fn ->
      restore_env(:disposable_domains_file, original_domains_file)
      restore_env(:source, original_source)
      restore_env(:url_options, original_url_options)
      if Process.whereis(Disposable), do: apply(Disposable, :reload, [])
    end)

    :ok
  end

  test "legacy start_link and child_spec keep the supervisor contract" do
    store = Process.whereis(Disposable)

    assert {:error, {:already_started, ^store}} = apply(Disposable, :start_link, [])
    assert {:error, {:already_started, ^store}} = apply(Disposable, :start_link, [[]])

    assert %{id: Disposable, start: {Disposable, :start_link, [[source: :bundled]]}} =
             Disposable.child_spec(source: :bundled)
  end

  test "lookup/1 returns structured valid and invalid outcomes" do
    assert {:ok, true} = Disposable.lookup("user@ALLTEMPMAIL.com")
    assert {:ok, false} = Disposable.lookup("user@example.com")
    assert {:error, :invalid_email} = Disposable.lookup("not-an-email")
    assert {:error, :invalid_email} = Disposable.lookup(nil)
  end

  test "disposable?/1 collapses invalid input and check/1 remains compatible" do
    assert Disposable.disposable?("user@alltempmail.com")
    refute Disposable.disposable?("user@example.com")
    refute Disposable.disposable?("invalid_email")
    assert legacy_check("user@alltempmail.com")
    refute legacy_check("invalid_email")
  end

  test "email matching is exact and case insensitive" do
    assert Disposable.disposable?("user@ALLTEMPMAIL.com")
    refute Disposable.disposable?("user@sub.alltempmail.com")
    refute Disposable.disposable?("user name@alltempmail.com")
    refute Disposable.disposable?("user@@alltempmail.com")
    refute Disposable.disposable?(<<255, "@alltempmail.com">>)
  end

  test "reload/0 serially replaces the active generation" do
    path = temporary_domains_file()
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "example.test\r\n# ignored\r\n")
    Application.put_env(:disposable, :source, {:file, path})
    assert :ok = apply(Disposable, :reload, [])
    refute Disposable.disposable?("user@alltempmail.com")
    assert Disposable.disposable?("user@example.test")

    File.write!(path, "newdisposable.test\n")
    assert :ok = apply(Disposable, :reload, [])
    refute Disposable.disposable?("user@example.test")
    assert Disposable.disposable?("user@newdisposable.test")
  end

  test "failed reload preserves the previous generation" do
    path = temporary_domains_file()
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "not a domain\n")
    Application.put_env(:disposable, :source, {:file, path})

    assert {:error, {:file_error, ^path, {:invalid_domain, %{line: 1, domain: "not a domain"}}}} =
             apply(Disposable, :reload, [])

    assert Disposable.disposable?("user@alltempmail.com")
  end

  test "configured file failures are explicit and empty files are rejected" do
    path = temporary_domains_file()
    Application.put_env(:disposable, :source, {:file, path})

    assert {:error, {:file_error, ^path, :enoent}} = apply(Disposable, :reload, [])
    assert Disposable.disposable?("user@alltempmail.com")

    File.write!(path, "\n# comments only\n")
    assert {:error, {:file_error, ^path, :empty_domain_list}} = apply(Disposable, :reload, [])
    assert Disposable.disposable?("user@alltempmail.com")
    File.rm!(path)
  end

  test "new source configuration wins over the deprecated file key" do
    path = temporary_domains_file()
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "new-source.test\n")
    Application.put_env(:disposable, :source, :bundled)
    Application.put_env(:disposable, :disposable_domains_file, "/missing/legacy-domains.txt")

    assert :ok = apply(Disposable, :reload, [])
    assert Disposable.disposable?("user@alltempmail.com")
    refute Disposable.disposable?("user@new-source.test")
  end

  test "lookup/1 distinguishes an unavailable store" do
    store = Process.whereis(Disposable)
    assert is_pid(store)
    assert Process.unregister(Disposable)

    on_exit(fn ->
      if Process.whereis(Disposable) == nil and Process.alive?(store), do: Process.register(store, Disposable)
    end)

    assert {:error, :not_running} = Disposable.lookup("user@alltempmail.com")
    refute Disposable.disposable?("user@alltempmail.com")
  end

  test "Http.fetch/3 rejects invalid URLs, timeouts, and CRLF headers" do
    assert {:error, :invalid_url} = Disposable.Http.fetch("not a URL")
    assert {:error, :invalid_url} = Disposable.Http.fetch("http:///path")
    assert {:error, :invalid_url} = Disposable.Http.fetch(<<255, "/path">>)
    assert {:error, :invalid_url} = Disposable.Http.fetch(123)
    assert {:error, :invalid_timeout} = Disposable.Http.fetch("http://localhost", [], 0)
    assert {:error, :invalid_timeout} = Disposable.Http.fetch("http://localhost", [], nil)
    assert {:error, :invalid_headers} = Disposable.Http.fetch("http://localhost", [{"x-test", 1}])
    assert {:error, :invalid_headers} = Disposable.Http.fetch("http://localhost", nil)

    assert {:error, :invalid_headers} =
             Disposable.Http.fetch("http://localhost", [{"x-test", "safe\r\nInjected: yes"}])
  end

  test "Http.fetch/3 returns stable transport errors" do
    assert {:error, {:transport, _reason}} = Disposable.Http.fetch("http://127.0.0.1:1", [], 100)
  end

  defp legacy_check(email), do: apply(Disposable, :check, [email])

  defp restore_env(key, nil), do: Application.delete_env(:disposable, key)
  defp restore_env(key, value), do: Application.put_env(:disposable, key, value)

  defp temporary_domains_file do
    Path.join(System.tmp_dir!(), "disposable-#{System.unique_integer([:positive])}.txt")
  end
end
