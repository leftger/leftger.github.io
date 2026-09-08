# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-09-08

### Added

- Timestamped backups of pre-existing dotfiles and Git configs before
  modification, stored under `~/.local/state/leftger-bootstrap/backups/`.
- `--rollback` mode that restores the newest backup of user dotfiles/configs.
- Persistent install logs under `~/.cache/leftger-bootstrap/`.
- Bootstrap version state under `~/.local/state/leftger-bootstrap/version`.
- `--check-update` and `--version` CLI flags.
- Bootstrap update notification inside `~/.local/bin/full-upgrade`.
- Positive `--*-only` execution modes:
  - `--locale-only`
  - `--timezone-only`
  - `--system-only`
  - `--core-only`
  - `--tools-only`
  - `--embedded-only`
  - `--zsh-only`
  - `--dotfiles-only`
  - `--rust-only`
  - `--zed-only`
- Dual licensing under MIT and Apache-2.0.
- Repository-local `.githooks/pre-commit` hook that runs ShellCheck on staged
  shell scripts (warning severity, matching CI).
- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, and
  this `CHANGELOG.md`.

### Changed

- Logging helpers now append plain-text entries to the active install log.
- Final summary now reports bootstrap version, log path, backup path, and the
  rollback one-liner.
- Help output and README updated with the new flags and safety features.

## [0.1.0] - 2026-09-07

### Added

- Public GitHub Pages site (`index.html`).
- Single-file `bootstrap.sh` with remote `curl | sh` support.
- Ubuntu/Debian APT and macOS Homebrew bootstrap support.
- Locale, timezone, core development, CLI, embedded ARM, Zsh, dotfiles,
  Rust, and Zed installation sections.
- `--skip-*` flags, `--timezone`, `--dry-run`, and `--help`.
- Curated dotfiles: Vim, Tmux, EditorConfig, Git hooks/templates, aliases,
  and the `full-upgrade` helper.
- ShellCheck lint workflow.
