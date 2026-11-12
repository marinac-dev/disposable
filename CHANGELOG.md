# Changelog

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
