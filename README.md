# leftger.github.io

Personal website and automated Linux workstation bootstrapping service for [**@leftger**](https://github.com/leftger).

## 🚀 One-Liner Install

To bootstrap a fresh Ubuntu / Debian installation:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh
```

Or pass custom flags (e.g. timezone or dry-run):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --timezone America/Phoenix
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --dry-run
```

---

## 🛠️ What Gets Installed & Configured

1. **System Maintenance**: `apt update`, `full-upgrade`, `dist-upgrade`, `autoremove` (non-interactive, config-preserving).
2. **Localization & Timezone**: `en_US.UTF-8` generated and set system-wide; timezone set to `America/Phoenix` (configurable).
3. **Core Development**: `build-essential`, `cmake`, `ninja-build`, `clang`, `lld`, `llvm`, `pkg-config`, `libssl-dev`, `git`, `git-lfs`, `jq`, `tmux`, `tree`.
4. **Modern CLI Productivity**: `vim`, `btop`, `mosh`, `binutils`, `ripgrep`, `fd-find` (`fd`), `bat` (`bat`), `fzf`.
5. **Embedded ARM Toolchain**: `gcc-arm-none-eabi`, `binutils-arm-none-eabi`, `libnewlib-arm-none-eabi`, `libstdc++-arm-none-eabi-newlib`, `gdb-multiarch`.
6. **Hardware Access**: Adds user to `dialout` and `plugdev` groups; installs `probe-rs` udev rules for CMSIS-DAP, ST-Link, and J-Link debuggers.
7. **Shell & Terminal**: `zsh` + Oh-My-Zsh configured as default user shell with plugins:
   - `git`, `sudo`, `cargo`, `rust`, `extract`, `z`, `colored-man-pages`, `command-not-found`, `zsh-autosuggestions`, `zsh-syntax-highlighting`.
8. **Curated Dotfiles**:
   - `~/.vimrc` with Badwolf theme, line numbers, automatic trailing whitespace stripping, and 4-space indentation.
   - `~/.bash_aliases` with directory navigation (`..`, `...`), parallel compilation (`mk='make -j$(nproc)'`), and git web viewer (`gh`).
   - Git defaults: `core.editor = vim`, `init.defaultBranch = main`, and `git pull-all` alias.
9. **Rust Ecosystem**: `rustup` stable toolchain, Cortex-M targets (`thumbv6m`, `thumbv7m`, `thumbv7em`, `thumbv7em-none-eabihf`, `thumbv8m.main-none-eabihf`), RISC-V targets, `probe-rs`, `cargo-binstall`, `cargo-deny`, and `cargo-llvm-cov`.

---

## ⚙️ CLI Flags

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-t`, `--timezone <TZ>` | Set system timezone | `America/Phoenix` |
| `--skip-upgrade` | Skip `apt full-upgrade` and `apt dist-upgrade` | `false` |
| `--skip-embedded` | Skip ARM GCC toolchain, probe-rs, and udev rules | `false` |
| `--skip-rust` | Skip Rust toolchain and cargo tools | `false` |
| `--skip-zsh` | Skip Zsh, Oh-My-Zsh, and shell change | `false` |
| `--skip-tools` | Skip modern CLI productivity tools | `false` |
| `--skip-dotfiles` | Skip curated .vimrc, themes, and shell aliases | `false` |
| `--dry-run` | Print proposed actions without making modifications | `false` |
| `-h`, `--help` | Display help screen and exit | |
