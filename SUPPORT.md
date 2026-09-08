# Support

Thanks for using `leftger.github.io`! This is a personal project, so support is
provided on a best-effort basis.

## Getting Help

1. **Read the docs** — start with the [README](README.md).
2. **Open an issue** — use the
   [GitHub issue tracker](https://github.com/leftger/leftger.github.io/issues)
   for bugs, feature requests, and questions.
3. **Email** — for private/security-sensitive topics, email
   [leftger@gmail.com](mailto:leftger@gmail.com).

## When Opening an Issue

Include:

- Your operating system and architecture (`uname -a`).
- Whether you ran from a local checkout or via the remote one-liner.
- The exact command you used.
- The output, especially any `[ERROR]` or `[WARN]` lines.
- Whether you used `--dry-run`, `--rollback`, or any `--*-only` mode.

For bootstrapping problems, you can inspect the install log at:

```text
~/.cache/leftger-bootstrap/bootstrap-*.log
```

and the latest backup at:

```text
~/.local/state/leftger-bootstrap/backups/<latest-timestamp>/
```

## Scope

We can help with:

- Using `bootstrap.sh` and its CLI flags.
- Dotfile installation behavior.
- Shell aliases and Git hook behavior shipped in `dotfiles/`.

We cannot provide general Linux/macOS administration support or support for
third-party tools installed by the bootstrap (APT/Homebrew packages, rustup,
Zed, Oh-My-Zsh, etc.) beyond the integration provided here.

## Expectations

This project has no SLA. Responses depend on maintainer availability.
