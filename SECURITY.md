# Security

S-Display changes system display settings. Turning on Flexible HiDPI asks for your administrator
password and writes a display override file as root, so anything that could let someone else run
commands as root, write other files, or tamper with releases is treated as serious.

## Supported versions

Only the **latest release** on the [Releases page](https://github.com/SLyHuy/S-Display/releases/latest)
gets security fixes. Please keep S-Display up to date.

## Reporting a vulnerability

**Do not open a public issue** for a security problem.

Report it privately on GitHub: open the repository's **Security** tab → **Report a vulnerability**, or go
straight to [github.com/SLyHuy/S-Display/security/advisories/new](https://github.com/SLyHuy/S-Display/security/advisories/new).
Only you and the maintainer can see the report.

Please include:
- The S-Display and macOS versions, and your Mac model.
- Steps to reproduce, and the impact (what can be run or written, by whom).
- A fix or mitigation, if you have one.

The maintainer aims to reply within a few days, confirm the issue with you, and publish a fix
crediting you (if you want).

## What counts as a vulnerability

- Running commands, or writing files other than `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-*/DisplayProductID-*`,
  through the administrator prompt (for example by injecting into the command S-Display builds).
- S-Display making network connections or sending any data off the Mac (it has no networking code).
- A release that does not match the source code, or a build/release pipeline that could be made to ship other code.

Bugs where a display stays dark or picks a wrong mode are not security issues; please open a normal issue.

## Verifying a release

Every release is built by GitHub Actions from this repository's source and carries a build provenance
attestation. Check a download with the [GitHub CLI](https://cli.github.com):

```bash
gh attestation verify S-Display-x.y.z.dmg -R SLyHuy/S-Display
```
