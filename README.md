# Warding [![Gem Version](https://badge.fury.io/rb/warding.svg)](https://badge.fury.io/rb/warding)

> Custom Arch Linux installer designed for security assessments and pentesting.

## Installation

Install warding by using the `gem install` command.

```bash
gem install warding
```

Or use the quick install method:

```bash
wget -qO- https://raw.githubusercontent/marlospomin/warding/master/debug/quick-install.sh
export PATH="`ruby -e 'puts Gem.user_dir'`/bin:$PATH"
warding
```

## Usage

1. Download Arch Linux.
2. Boot the live ISO.
3. Install warding either from source or with the gem command.
4. Run the binary executable `warding` and fill in the prompts.
5. Enjoy.

## Tasklist

* Refactor.
* Suppress outputs.
* Add extra checks.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/marlospomin/warding.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
