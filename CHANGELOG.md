# Changelog

## Unreleased

### Added

- `Disposable.status/0` reports the store lifecycle: `:ready` or `:refreshing`,
  the active generation, its source and size, and the last failed refresh.

### Changed

- `Disposable.reload/0` is no longer deprecated. It is the only way to re-read
  the configured source at runtime and had no replacement.

### Fixed

- `mix.exs` declares preferred environments in `cli/0`, removing the
  `:preferred_cli_env` deprecation warning on newer Elixir releases.

## 0.2.0

### Added

- `Disposable.lookup/1` with explicit `:invalid_email` and `:not_running` outcomes.
- `Disposable.disposable?/1` as the boolean convenience predicate.
- Bundled, file, and administrator-controlled URL sources.
- UTF-8 domain parsing limits and line-numbered validation errors.
- ETS-backed lookups with serialized, atomic generation replacement.

### Changed

- URL loading uses Req with redirects, retries, decoding, and decompression disabled.
- Response bytes are bounded while streaming, and actual HTTP statuses are preserved.
- The bundled snapshot is normalized, deduplicated, sorted, and excludes reviewed sensitive domains.

### Deprecated

- `Disposable.check/1` in favor of `Disposable.disposable?/1`.
- `Disposable.start_link/1` and `Disposable.reload/0` as direct lifecycle compatibility APIs.
- `Disposable.Http.get/1..3` in favor of `Disposable.load_url/1` for domain sources.
- `:disposable_domains_file` in favor of `:source`.
