defmodule Disposable.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  setup do
    _store = Process.whereis(Disposable) || start_supervised!(Disposable)
    on_exit(fn -> apply(Disposable, :reload, []) end)
    :ok
  end

  test "init reports source failures and metadata conflicts" do
    path = Path.join(System.tmp_dir!(), "disposable-store-#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)

    assert {:stop, {:file_error, ^path, :enoent}} =
             Disposable.Store.init(source: {:file, path})

    File.write!(path, "store-init.test\n")

    assert {:stop, :not_running} = Disposable.Store.init(source: {:file, path})
  end

  test "store calls return not_running while the registration is absent" do
    store = Process.whereis(Disposable)
    assert is_pid(store)
    assert Process.unregister(Disposable)

    try do
      assert {:error, :not_running} = Disposable.Store.reload()
      assert {:error, :not_running} = Disposable.Store.replace(MapSet.new(["store.test"]))
    after
      Process.register(store, Disposable)
    end
  end

  test "the store start_link default delegates to GenServer" do
    store = Process.whereis(Disposable)
    assert {:error, {:already_started, ^store}} = Disposable.Store.start_link()
  end

  test "failed publication cleans up the new table and preserves state" do
    state = %{
      metadata_table: make_ref(),
      active_table: make_ref(),
      source: :bundled,
      url_options: []
    }

    assert {:reply, {:error, :not_running}, ^state} =
             Disposable.Store.handle_call({:replace, MapSet.new(["store.test"])}, self(), state)
  end

  test "replacement tolerates an already deleted old table" do
    metadata_table = :ets.new(:store_test_metadata, [:set])

    state = %{
      metadata_table: metadata_table,
      active_table: make_ref(),
      source: :bundled,
      url_options: []
    }

    assert {:reply, :ok, new_state} =
             Disposable.Store.handle_call({:replace, MapSet.new(["store.test"])}, self(), state)

    active_table = new_state.active_table
    assert [{:active, ^active_table}] = :ets.lookup(metadata_table, :active)
    :ets.delete(metadata_table)
    :ets.delete(active_table)
  end

  test "failed replacement preserves the active generation" do
    domains = MapSet.new(["store-old.test"])
    assert :ok = Disposable.Store.replace(domains)
    assert {:ok, true} = Disposable.lookup("user@store-old.test")

    assert {:error, :invalid_domain} = Disposable.Store.replace(MapSet.new(["invalid domain"]))
    assert {:ok, true} = Disposable.lookup("user@store-old.test")
  end

  test "concurrent replacements and readers do not expose partial generations" do
    generations = [
      MapSet.new(["generation-a.test", "shared.test"]),
      MapSet.new(["generation-b.test", "shared.test"])
    ]

    replacements =
      1..40
      |> Enum.map(fn index -> Enum.at(generations, rem(index, 2)) end)

    replacement_tasks =
      Task.async_stream(replacements, &Disposable.Store.replace/1,
        max_concurrency: 8,
        ordered: false
      )

    reader_tasks =
      Task.async_stream(
        1..200,
        fn _index ->
          [Disposable.lookup("user@generation-a.test"), Disposable.lookup("user@generation-b.test")]
        end,
        max_concurrency: 16,
        ordered: false
      )

    assert Enum.all?(replacement_tasks, fn {:ok, :ok} -> true end)

    assert Enum.all?(reader_tasks, fn {:ok, results} ->
             Enum.all?(results, &match?({:ok, value} when is_boolean(value), &1))
           end)
  end
end
