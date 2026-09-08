# Contributing to leftger.github.io

Thanks for taking the time to contribute! This repository hosts:

- `index.html` — the personal landing page.
- `bootstrap.sh` — the single-file Linux/macOS bootstrap service.
- `dotfiles/` — the curated dotfiles, shell aliases, Git hooks, and helper
  scripts deployed by `bootstrap.sh`.

## Ground Rules

- Keep changes backward compatible where possible. `bootstrap.sh` is often run
  via `curl ... | sh`, so it should remain POSIX-bootstrappable and Bash-safe.
- Never put secrets, personal keys, or private credentials in dotfiles.
- Do not break the existing `--skip-*`, `--dry-run`, or new `--*-only` flags
  without a changelog entry.
- Test your changes before opening a pull request:
  - `bash -n bootstrap.sh`
  - `./bootstrap.sh --help`
  - `./bootstrap.sh --dry-run --dotfiles-only` on a disposable machine/VM.
  - `bash -n dotfiles/bin/full-upgrade`
  - `shellcheck -S warning bootstrap.sh dotfiles/bin/full-upgrade dotfiles/.githooks/_dispatch`
- The repository-local pre-commit hook (`.githooks/pre-commit`) runs ShellCheck
  on staged shell scripts at warning severity. Enable it in a fresh clone with:

  ```bash
  git config core.hooksPath .githooks
  ```

  Install ShellCheck from your package manager or from
  <https://github.com/koalaman/shellcheck>.

## Development Workflow

1. Fork the repository.
2. Create a branch with a descriptive name:
   ```bash
   git checkout -b feat/description
   ```
3. Make your changes.
4. Run the syntax/lint checks locally. GitHub Actions also runs ShellCheck on
   every push and pull request.
5. Commit using conventional commit messages (this repo deploys a
   `~/.gitmessage` template for that style):
   ```text
   feat(bootstrap): add timestamped backups and rollback
   fix(update): handle remote version check when curl is unavailable
   docs(readme): document --*-only modes
   ```
6. Open a pull request with a clear summary and test instructions.

## What Goes Where

| Change | File/directory |
| :--- | :--- |
| Installer flags / package logic | `bootstrap.sh` |
| Shell aliases / functions | `dotfiles/.bash_aliases` |
| Vim / tmux / editor settings | `dotfiles/.vimrc`, `dotfiles/.tmux.conf`, `dotfiles/.editorconfig` |
| Git defaults / hooks | `dotfiles/.gitmessage`, `dotfiles/.githooks/_dispatch`, `dotfiles/.git_template/` |
| System upgrade helper | `dotfiles/bin/full-upgrade` |
| Landing page content | `index.html` |
| Project docs / policies | `README.md`, `CHANGELOG.md`, `SECURITY.md`, `SUPPORT.md` |

## Reviewing

Changes that affect what the installer writes to a user's home directory should
be reviewed especially carefully because they modify real user configurations.
Prefer additive behavior over destructive overwrites, and keep the backup /
rollback behavior intact.

## License

By contributing you agree that your contributions are licensed under the same
terms as this project: [MIT](LICENSE-MIT) and
[Apache-2.0](LICENSE-APACHE), at your option.
