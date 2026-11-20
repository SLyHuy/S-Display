## Install

### Homebrew
```bash
brew install --cask SLyHuy/tap/s-display
```
Or update an existing install (choose **Turn All On & Quit** first if a display is off):
```bash
brew upgrade --cask s-display
```

### Manual download
1. Download **S-Display-{{VERSION}}.dmg** below (or the `.zip`), open it and drag **S-Display.app** into **Applications**.

### First launch
S-Display is free and not notarized by Apple, so on first launch macOS will say **"S-Display" Not Opened: Apple could not verify "S-Display" is free of malware…**.
This is **normal for every app that is not notarized by Apple** and does not mean malware was found. To be sure, [verify the download](#verify-the-download) first.
- Click **Done** (not *Move to Trash*).
- Open **System Settings → Privacy & Security**, scroll to **Security** and click **Open Anyway** next to *"S-Display" was blocked…*, then confirm with your password or Touch ID.
- Or run: `xattr -dr com.apple.quarantine /Applications/S-Display.app`

S-Display lives in the menu bar (display icon). Requires an **Apple Silicon Mac** and **macOS 14 or later**.

**Updating manually:** quit S-Display (choose **Turn All On & Quit** if a display is off), replace the app in Applications, open it again.

**If a display stays dark:** press **⌃⌥⌘0**, or click **Turn On** in S-Display, or unplug and replug that display's cable.

## Verify the download
These files are built by GitHub Actions straight from this repository's source and carry a build provenance attestation. Check with the [GitHub CLI](https://cli.github.com):
```
gh attestation verify S-Display-{{VERSION}}.dmg -R SLyHuy/S-Display
```
Or compare the checksum:
```
shasum -a 256 S-Display-{{VERSION}}.dmg
```
with the matching line in `S-Display-{{VERSION}}.sha256`.

---
**S-Display**: turn displays fully off (BlackOut) and get sharp HiDPI scaling with a UI-size slider on any monitor. No network access, no telemetry.
MIT License © 2026 Huy Ly · Source: https://github.com/SLyHuy/S-Display · Report a vulnerability: [SECURITY.md](https://github.com/SLyHuy/S-Display/blob/main/SECURITY.md)
