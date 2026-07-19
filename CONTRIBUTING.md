# Contributing

Thanks for your interest in improving this project. It builds a security-hardened,
multi-environment KVM workstation, so contributions are held to a careful bar:
changes must not weaken environment isolation or the trusted computing base.

## Ground rules

- **Isolation is the product.** Anything that could let one VM reach another, or
  that hands a guest control over host-enforced policy (firewall, VPN, USB, disk
  encryption), needs a strong justification and clear reasoning in the PR.
- **Additive and reversible.** Prefer opt-in flags in `config.env.example` over
  changing default behaviour. Every script is expected to be idempotent and safe
  to re-run.
- **No secrets in git.** Real secrets live only in `config.env` (git-ignored) or
  on the appliance. Never commit passwords, PSKs, LUKS passphrases or WireGuard
  keys. Only `config.env.example` (the template) is tracked.

## Shell style

- Target POSIX `sh` for `lib/common.sh` (Alpine's default is busybox ash);
  scripts that need bashisms declare `#!/bin/bash`.
- Every executable script starts with `set -euo pipefail` (bash) or `set -eu`
  (POSIX sh), checks for root where needed (`require_root`), and validates its
  dependencies (`require_cmds`).
- Quote expansions, and prefer `mktemp` over predictable temp paths.

## Before you open a PR

Run ShellCheck locally — CI runs the same check and fails on warnings:

```sh
shellcheck -x -S warning lib/*.sh host/*.sh environments/*.sh installer/*.sh build/*.sh
```

Where practical, test on a spare machine or VM. Several features
(disk encryption, Secure Boot, TPM unlock) are explicitly brick-prone and must
never be validated only on your primary device.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`,
`fix:`, `docs:`, `ci:`, `refactor:`, ...). Keep each commit to one logical change
and explain the "why" in the body when it isn't obvious.
