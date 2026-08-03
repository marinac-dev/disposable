# Migrating to 0.2

## Lookup Results

`check/1` still returns a boolean, but new code should use the explicit API:

```elixir
case Disposable.lookup(email) do
  {:ok, true} -> :disposable
  {:ok, false} -> :accepted
  {:error, :invalid_email} -> :invalid
  {:error, :not_running} -> :retry_later
end
```

Use `Disposable.disposable?/1` when intentionally collapsing invalid input and
store failures to `false`. `Disposable.check/1` remains available with a
deprecation warning until before 1.0.

## Configuration

Use the canonical source configuration:

```elixir
config :disposable,
  source: :bundled,
  url_options: [
    timeout: 15_000,
    max_body_bytes: 5 * 1024 * 1024
  ]
```

The old `:disposable_domains_file` key remains supported during 0.2, but is
deprecated. If both keys are present, `:source` wins. A configured missing file
now returns an explicit file error instead of silently falling back to the
bundled snapshot.

## URL Loading

`Disposable.load_url/1` remains an administrator-controlled refresh operation.
It does not mutate application configuration, follows no redirects, and leaves
the current generation unchanged after a failed request or invalid response.

`Disposable.Http.get/1..3` is retained only as a deprecated compatibility
wrapper. New code should not use it as a general-purpose HTTP client.

## Data Semantics

Domain matching remains exact. The parser accepts ASCII domains and ASCII
punycode labels, but does not perform Unicode IDNA conversion. Email validation
is intentionally limited and is not full RFC 5322 validation.
