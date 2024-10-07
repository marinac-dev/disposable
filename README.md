# Disposable

[![Hex.pm](https://img.shields.io/hexpm/v/disposable.svg)](https://hex.pm/packages/disposable)
[![Hex Docs](https://img.shields.io/badge/hex-docs-brightgreen.svg)](https://hexdocs.pm/disposable)

Disposable is an Elixir library for checking if an email address is from a disposable email service. It provides a fast, memory-efficient way to validate email domains against a known list of disposable email providers. With over 169.000 domains in the list, Disposable is a reliable tool for preventing users from signing up with temporary email addresses.

## Features

- Fast in-memory checking of email domains
- Easy to use API
- Configurable disposable domains list
- Ability to reload domains without application restart

## Installation

The package can be installed by adding `disposable` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:disposable, "~> 0.1.3"}
  ]
end
```

## Usage

### Basic usage

```elixir
iex> Disposable.check("user@gmail.com")
false

iex> Disposable.check("user@tempmail.com")
true
```

### Configuration

By default, Disposable uses a built-in list of disposable email domains. You can provide your own list by setting the `:disposable_domains_file` configuration in your `config.exs`:

```elixir
config :disposable, disposable_domains_file: "/path/to/your/domains.txt"
```

### Reloading domains

If you update your domains list, you can reload it without restarting your application:

```elixir
Disposable.reload()
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Acknowledgments

- Thanks to all contributors who have helped with this project.
- Special thanks to the maintainers of various disposable email domain lists that helped in creating our initial list.
