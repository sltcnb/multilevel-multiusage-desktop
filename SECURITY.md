# Security Policy

This project builds a security-hardened, multi-environment workstation whose
central guarantee is that three isolated VMs cannot reach one another. Security
reports are therefore taken seriously.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** — do not open a public
issue for anything exploitable.

- Preferred: open a [GitHub private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  via the repository's **Security** tab.
- Include: affected script(s)/commit, environment (host distro, hardware),
  reproduction steps, and the impact (especially any cross-VM leakage or a guest
  gaining influence over host-enforced policy).

Please allow a reasonable window for a fix before any public disclosure.

## Scope

Highest-priority concerns:

- **Cross-environment leakage** — any path by which one VM can reach another
  (network, shared storage, clipboard, USB, or host misconfiguration).
- **Guest escaping host-enforced controls** — the per-env firewall, egress
  whitelist, non-bypassable VPN, USB lockdown, or disk encryption are all meant
  to be enforced on the host and invisible to guests.
- **Secret exposure** — secrets leaking into the built image, into git, or being
  left at rest after `environments/scrub-secrets.sh` should have removed them.
- **Trusted-base weaknesses** — anything that expands the minimal Alpine host's
  attack surface or grants the unprivileged `kiosk` user unintended power.

## Design notes for reviewers

- Isolation is defense-in-depth: separate bridges + subnets, an nftables
  all-pairs DROP (by subnet *and* by bridge name), and libvirt per-network
  filtering. A report is more serious if it defeats more than one layer.
- Opt-in features flagged EXPERIMENTAL (disk encryption, Secure Boot, TPM
  unlock) are known to be brick-prone and are off by default; issues there are
  welcome but are treated as hardening rather than active regressions.
- Secrets belong only in the git-ignored `config.env` or on the appliance, never
  baked into a shipped image.
