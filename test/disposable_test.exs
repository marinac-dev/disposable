defmodule DisposableTest do
  use ExUnit.Case
  doctest Disposable

  setup do
    # Check if the Disposable agent is already running
    if Process.whereis(Disposable) == nil do
      start_supervised!(Disposable)
    end
    :ok
  end

  test "check/1 returns false for non-disposable email" do
    refute Disposable.check("user@gmail.com")
    refute Disposable.check("user@example.com")
  end

  test "check/1 returns true for disposable email" do
    assert Disposable.check("user@alltempmail.com")
  end

  test "check/1 is case insensitive" do
    result1 = Disposable.check("user@ALLTEMPMAIL.com")
    result2 = Disposable.check("user@alltempmail.com")
    assert result1 == result2
  end

  test "check/1 handles invalid email format" do
    refute Disposable.check("invalid_email")
    refute Disposable.check("@no_username.com")
    refute Disposable.check("no_at_sign.com")
  end

  test "reload/0 updates the domain list" do
    # This test assumes you can modify the domains file
    # You might need to mock File operations for this test
    original_result = Disposable.check("user@newdisposable.com")

    # Simulate adding a new domain to the file
    add_domain_to_file("newdisposable.com")
    Disposable.reload()

    new_result = Disposable.check("user@newdisposable.com")
    assert new_result != original_result

    # Clean up: remove the added domain
    remove_domain_from_file("newdisposable.com")
  end

  # Helper functions for file operations
  # These are simplistic and might need to be replaced with proper file handling or mocks
  defp add_domain_to_file(domain) do
    File.write!(domains_file_path(), "\n#{domain}", [:append])
  end

  defp remove_domain_from_file(domain) do
    content = File.read!(domains_file_path())
    updated_content = String.replace(content, "\n#{domain}", "")
    File.write!(domains_file_path(), updated_content)
  end

  defp domains_file_path do
    Application.app_dir(:disposable, "priv/domains.txt")
  end
end
