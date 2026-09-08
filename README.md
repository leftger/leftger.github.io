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
2. **Localization & Timezone**: `en_US.UTF-8` generated and set system-wide; timezone autodetected from host system (configurable via `--timezone`).
3. **Core Development**: `build-essential`, `cmake`, `ninja-build`, `clang`, `lld`, `llvm`, `pkg-config`, `libssl-dev`, `git`, `git-lfs`, `jq`, `tmux`, `tree`.
4. **Modern CLI Productivity**: `vim`, `btop`, `mosh`, `binutils`, `ripgrep`, `fd-find` (`fd`), `bat` (`bat`), `fzf` (with Ctrl+R, Ctrl+T, Alt+C shell integration).
5. **Embedded ARM Toolchain**: `gcc-arm-none-eabi`, `binutils-arm-none-eabi`, `libnewlib-arm-none-eabi`, `libstdc++-arm-none-eabi-newlib`, `gdb-multiarch`, `openocd`, `tio` (serial monitor), `libusb`, `libudev`.
6. **Hardware Access**: Adds user to `dialout` and `plugdev` groups; installs `probe-rs` udev rules for CMSIS-DAP, ST-Link, and J-Link debuggers.
7. **Shell & Terminal**: `zsh` + Oh-My-Zsh configured as default user shell with plugins:
   - `git`, `sudo`, `cargo`, `rust`, `extract`, `z`, `colored-man-pages`, `command-not-found`, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `my-completions` (dynamic `cdr <TAB>` completion).
   - Fast prompt response (`DISABLE_UNTRACKED_FILES_DIRTY="true"`).
   - URL paste fix (`DISABLE_MAGIC_FUNCTIONS="true"`).
   - Safe POSIX alias sourcing with `emulate ksh`.
8. **Curated Dotfiles & Utilities**:
   - `~/.vimrc` with Badwolf theme, line numbers, automatic trailing whitespace stripping, and 4-space indentation.
   - `~/.tmux.conf` with mouse support, TrueColor, 10,000 line scrollback, vi mode keys, and GitHub dark theme status bar.
   - `~/.gitmessage` standard conventional commit template.
   - `~/.editorconfig` standard cross-editor formatting rules.
   - `~/.hushlogin` to silence distracting login MOTD banners.
   - `~/.local/bin/full-upgrade` (alias: `up`): one-stop unattended updater for APT, Rust, Zed, Flatpak, Snap, pipx, npm, and WSL.
   - `~/.bash_aliases` with directory navigation (`..`, `...`), quick helpers (`mcd <dir>`, `cdr <repo>`, `refreshenv`, `up`), WSL interop (`cdw`, `exp`, `BROWSER="wslview"`, `usb-list`, `usb-attach`, `usb-detach`), parallel compilation (`mk='make -j$(nproc)'`), and git web viewer (`gh`).
   - Global `~/.gitignore` (`core.excludesfile`) for OS, editor, and log artifacts.
   - Git defaults & productivity: `core.editor = vim`, `init.defaultBranch = main`, `push.autoSetupRemote = true`, `rebase.autoStash = true`, `merge.autoStash = true`, `git caane`, `git caa`, `git cob`, `git apply-gitignore`, and `git pa`.
9. **Security & Cryptographic Keys**:
   - Automated check and creation of `ed25519` SSH key (`~/.ssh/id_ed25519`) if no SSH keys are present.
   - Automated creation of `ed25519` GPG key if none exists, auto-configuring `git commit.gpgsign true` and `user.signingkey`.
10. **Rust Ecosystem**: `rustup` stable toolchain, Cortex-M & RISC-V targets (`thumbv6m`, `thumbv7m`, `thumbv7em`, `thumbv7em-none-eabihf`, `thumbv8m.main-none-eabihf`, `riscv32imac`, `riscv32imc`), `probe-rs`, `cargo-binstall`, `cargo-binutils` (`cargo size`, `cargo objcopy`, `cargo objdump`), `espflash` / `cargo-espflash`, `cargo-generate`, `cargo-deny`, and `cargo-llvm-cov`.
11. **Zed Editor**: Installs latest stable release of high-performance [Zed](https://zed.dev) editor to `~/.local/bin/zed`.

---

## ⚙️ CLI Flags

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-t`, `--timezone <TZ>` | Set system timezone | `Auto-detected` |
| `--skip-upgrade` | Skip package manager and system upgrades | `false` |
| `--skip-embedded` | Skip ARM GCC toolchain, probe-rs, and udev rules | `false` |
| `--skip-rust` | Skip Rust toolchain and cargo tools | `false` |
| `--skip-zed` | Skip Zed editor installation | `false` |
| `--skip-zsh` | Skip Zsh, Oh-My-Zsh, and shell change | `false` |
| `--skip-tools` | Skip modern CLI productivity tools | `false` |
| `--skip-dotfiles` | Skip curated dotfiles, tmux, vim, and shell aliases | `false` |
| `--skip-keys` | Skip ED25519 SSH and GPG key generation | `false` |
| `--dry-run` | Print proposed actions without making modifications | `false` |
| `-h`, `--help` | Display help screen and exit | |

