# Warding

> Custom Arch Linux designed for security assessments and pentesting.

## Install

Boot Arch live with EFI enabled.

Run the following command to install warding:

```bash
# Basic installation
wget -qO- https://raw.githubusercontent.com/marlospomin/warding/master/install.sh | sh
```

By default the script will not install any theme, icons or tools. To enable that use `-e` to install eye candy features and `-t` to install all the basic tools.

```bash
# Install tools only, leaving theming for yourself
./install.sh -t
# Install everything
./install.sh -et
```

And that's it.

## License

Code released under the [MIT](LICENSE) license.
