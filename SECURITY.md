# Security Policy

## Supported Versions

`leftger.github.io` is a personal website and bootstrap repository. Security
fixes are applied to the `main` branch and then published to GitHub Pages.
Users should always install with the latest remote one-liner:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh
```

## Reporting a Vulnerability

Please **do not open a public issue** for security-sensitive reports.

Instead, email [leftger@gmail.com](mailto:leftger@gmail.com) with:

- A description of the vulnerability.
- Steps to reproduce, if known.
- Affected scripts/files, if known.
- Any suggested mitigation.

You should receive an acknowledgement within a few days. Please allow time for
a fix and disclosure before making the issue public.

## Security Notes for Users

- The bootstrap one-liner only ever fetches over HTTPS (`--proto '=https'`).
- The script may overwrite dotfiles after creating a timestamped backup under
  `~/.local/state/leftger-bootstrap/backups/`. You can restore the newest
  backup with:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --rollback
  ```
- Do not add passwords, API tokens, or private keys to this repository's
  dotfiles; they are public.
- SSH and GPG keys are only generated on the machine running the bootstrap;
  they are never uploaded or stored by this repository.
