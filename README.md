# Disposable

[![Hex.pm](https://img.shields.io/hexpm/v/disposable.svg)](https://hex.pm/packages/disposable)
[![Hex Docs](https://img.shields.io/badge/hex-docs-brightgreen.svg)](https://hexdocs.pm/disposable)

Disposable is an Elixir library for checking whether an email address uses a
disposable email service. It ships with a curated list of disposable domains
and provides fast, in-memory lookups.

## Requirements

- Elixir 1.18 or later
- OTP compatible with the selected Elixir release

## Features

- Fast, case-insensitive email-domain lookups
- Structured results for valid and invalid email addresses
- Bundled, file, and URL domain sources
- Atomic domain refreshes without restarting the application
- Bounded administrator-controlled URL loading

## Installation

Add `disposable` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:disposable, "~> 0.2.0"}
  ]
end
```

The application starts its domain store automatically.

## Usage

### Basic usage

```elixir
iex> Disposable.disposable?("user@alltempmail.com")
true

iex> Disposable.disposable?("user@gmail.com")
false
```

Use `lookup/1` when the reason for a negative result matters:

```elixir
case Disposable.lookup(email) do
  {:ok, true} -> :disposable
  {:ok, false} -> :accepted
  {:error, :invalid_email} -> :invalid
  {:error, :not_running} -> :retry_later
end
```

`disposable?/1` returns `false` for invalid input or an unavailable store.
`check/1` is retained as a deprecated compatibility alias.

Domain matching is exact and case-insensitive. Email validation is intentionally
limited rather than full RFC 5322 validation; ASCII domains and ASCII punycode
labels are accepted, but Unicode labels are not converted to IDNA.

## Configuration

The bundled list is used by default. Configure a bundled, file, or URL source
in `config.exs`:

```elixir
config :disposable,
  source: {:file, "/path/to/your/domains.txt"},
  url_options: [
    timeout: 15_000,
    max_body_bytes: 5 * 1024 * 1024
  ]
```

Supported sources are `:bundled`, `{:file, path}`, and `{:url, url}`. The
default source performs no network access at startup. The older
`:disposable_domains_file` setting is supported for compatibility, but
`:source` takes precedence when both are configured.

Domain files are UTF-8, one domain per line. Blank lines and lines beginning
with `#` are ignored. Values are trimmed, lowercased, deduplicated, and
validated. CRLF input is supported.

## Refreshing

Reload the configured source without restarting the application:

```elixir
Disposable.reload()
```

`reload/0` is retained as a deprecated compatibility API. It returns `:ok` or
`{:error, reason}`, and a failed refresh leaves the current list unchanged.

For an administrator-controlled URL refresh, use:

```elixir
Disposable.load_url("https://example.com/disposable-domains.txt")
```

URL requests do not follow redirects or retries and are bounded by the
configured timeouts and response-size limit. Failed requests do not replace the
active list.

## Development

```bash
mix test
mix test.unit
mix test.integration
mix check
```

## Data

The bundled list contains 169,267 domains at this revision. It is not a
guarantee that every disposable provider is included.

## Migration

See [Migrating to 0.2](guides/migrating-to-0.2.md) for the API and configuration
changes from 0.1.x.

## License

This project is licensed under the [MIT License](LICENSE.md).
