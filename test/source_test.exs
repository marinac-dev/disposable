defmodule Disposable.SourceTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @domain_file Application.app_dir(:disposable, "priv/domains.txt")
  @domain_count 169_267
  @domain_checksum "5eefcafdc6c6c38c7e07f571c41f64e4e34a406640f01ce259c6997853be574f"

  test "parses CRLF, comments, whitespace, case, and duplicates" do
    assert {:ok, domains} = Disposable.Source.parse("  EXAMPLE.TEST  \r\n# comment\r\nexample.test\n")
    assert domains == MapSet.new(["example.test"])
  end

  test "reports invalid encoding and line numbers" do
    assert {:error, :invalid_encoding} = Disposable.Source.parse(<<255, "\n">>)

    assert {:error, {:invalid_domain, %{line: 2, domain: "not a domain"}}} =
             Disposable.Source.parse("valid.test\nnot a domain\n")
  end

  test "enforces line, source, and domain-count limits" do
    assert {:error, {:line_too_long, %{line: 1, max_bytes: 5}}} =
             Disposable.Source.parse("valid.test\n", max_line_bytes: 5)

    assert {:error, {:source_too_large, 5}} = Disposable.Source.parse("valid.test\n", max_source_bytes: 5)

    assert {:error, {:domain_count_exceeded, %{line: 2, max: 1}}} =
             Disposable.Source.parse("one.test\ntwo.test\n", max_domain_count: 1)
  end

  test "rejects malformed source descriptors and parser inputs" do
    assert {:error, :invalid_source} = Disposable.Source.load(:unknown)
    assert {:error, :invalid_source} = Disposable.Source.load(:bundled, :not_a_list)
    assert {:error, :invalid_source} = Disposable.Source.load(:bundled, [:not_a_keyword])
    assert {:error, :invalid_source} = Disposable.Source.load({:file, ""})
    assert {:error, :invalid_source} = Disposable.Source.load({:file, <<255>>})
    assert {:error, :invalid_source} = Disposable.Source.load({:file, 123})
    assert {:error, :invalid_url} = Disposable.Source.load({:url, ""})
    assert {:error, :invalid_url} = Disposable.Source.load({:url, 123})

    assert {:error, :invalid_source} =
             Disposable.Source.load({:url, "http://localhost"}, url_options: [:bad])

    assert {:error, :invalid_source} =
             Disposable.Source.load({:url, "http://localhost"}, url_options: :bad)

    assert {:error, :invalid_source} = Disposable.Source.parse("valid.test\n", [:not_a_keyword])
    assert {:error, :invalid_encoding} = Disposable.Source.parse("valid.test\n", :not_a_list)
    assert {:error, :invalid_encoding} = Disposable.Source.parse(:not_binary)
    assert {:error, :invalid_domain_list} = Disposable.Source.validate_domains([])
    assert {:error, :invalid_domain} = Disposable.Source.validate_domains(MapSet.new(["not a domain"]))
    refute Disposable.Source.valid_domain?(nil)
  end

  test "loads explicit files and applies parser size options" do
    path = temporary_domains_file()
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "Example.TEST\n")

    assert {:ok, domains} = Disposable.Source.load({:file, path})
    assert domains == MapSet.new(["example.test"])

    assert {:ok, ^domains} = Disposable.Source.load({:file, path}, max_source_bytes: 100)
    assert {:ok, ^domains} = Disposable.Source.load({:file, path}, max_body_bytes: 100)
  end

  test "falls back to the deprecated file configuration" do
    original_source = Application.get_env(:disposable, :source)
    original_file = Application.get_env(:disposable, :disposable_domains_file)
    path = temporary_domains_file()

    on_exit(fn ->
      restore_env(:source, original_source)
      restore_env(:disposable_domains_file, original_file)
      File.rm(path)
    end)

    Application.delete_env(:disposable, :source)
    Application.put_env(:disposable, :disposable_domains_file, path)

    assert Disposable.Source.configured_source() == {:file, path}
  end

  test "rejects non-positive parser limits" do
    for {key, value} <- [
          {:max_source_bytes, 0},
          {:max_line_bytes, 0},
          {:max_domain_count, 0}
        ] do
      assert {:error, :invalid_source} = Disposable.Source.parse("valid.test\n", [{key, value}])
    end
  end

  test "enforces label and total domain length boundaries" do
    valid_domain =
      [String.duplicate("a", 63), String.duplicate("b", 63), String.duplicate("c", 63), String.duplicate("d", 61)]
      |> Enum.join(".")

    assert byte_size(valid_domain) == 253
    assert Disposable.Source.valid_domain?(valid_domain)
    refute Disposable.Source.valid_domain?(valid_domain <> "a")
    refute Disposable.Source.valid_domain?(String.duplicate("a", 64) <> ".test")
  end

  test "accepts ASCII punycode and rejects Unicode labels" do
    assert Disposable.Source.valid_domain?("xn--bcher-kva.de")
    refute Disposable.Source.valid_domain?("bücher.de")
  end

  test "bundled snapshot is encoded, sorted, unique, and checksummed" do
    contents = File.read!(@domain_file)
    assert String.valid?(contents)
    assert :ok = Disposable.Source.validate_domains(elem(Disposable.Source.parse(contents), 1))

    assert {:ok, domains} = Disposable.Source.parse(contents)
    values = MapSet.to_list(domains)
    assert length(values) == @domain_count
    lines = contents |> String.split("\n", trim: true)
    assert lines == Enum.sort(lines)
    assert length(values) == length(Enum.uniq(values))
    assert MapSet.member?(domains, "alltempmail.com")
    refute MapSet.member?(domains, "army.gov")
    refute MapSet.member?(domains, "harvard.ac.uk")
    refute MapSet.member?(domains, "perl.mil")
    refute MapSet.member?(domains, "whitehouse.gov")
    assert byte_size(contents) == 2_606_402
    assert Base.encode16(:crypto.hash(:sha256, contents), case: :lower) == @domain_checksum
  end

  defp restore_env(key, nil), do: Application.delete_env(:disposable, key)
  defp restore_env(key, value), do: Application.put_env(:disposable, key, value)

  defp temporary_domains_file do
    Path.join(System.tmp_dir!(), "disposable-source-#{System.unique_integer([:positive])}.txt")
  end
end
