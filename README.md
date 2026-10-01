# S-Display

[![CI](https://github.com/SLyHuy/S-Display/actions/workflows/ci.yml/badge.svg)](https://github.com/SLyHuy/S-Display/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SLyHuy/S-Display)](https://github.com/SLyHuy/S-Display/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A small, free macOS menu bar app with two display tools:

- **BlackOut**: turn a display fully off. It leaves the layout, windows move to the remaining displays,
  the monitor gets no signal and the GPU stops drawing it. Like Lunar's BlackOut or BetterDisplay's Disconnect.
- **Sharp HiDPI scaling**: Retina-style rendering on 1440p and 4K monitors, with a slider for how large
  text and UI look. Flexible HiDPI adds a size every 16 points. Like BetterDisplay's Flexible Scaling.

No network access, no telemetry, no account.

**Requirements:** an Apple Silicon Mac (M1 or later) and macOS 14 Sonoma or later.

## Install

S-Display is free and released **without an Apple certificate** (ad-hoc signed), so the first launch takes a few extra steps:

1. Download `S-Display-x.y.z.dmg` (or the `.zip`) from the [Releases page](https://github.com/SLyHuy/S-Display/releases/latest).
2. Open the DMG and drag **S-Display.app** into **Applications**.
3. Open S-Display. macOS blocks it because it is not notarized:
   open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   Or run in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/S-Display.app
   ```
4. Click the display icon in the menu bar. Turn on **Launch at login** if you want it there after every restart.

To check a download really was built from this repository:
`gh attestation verify S-Display-x.y.z.dmg -R SLyHuy/S-Display`, or compare `shasum -a 256` with the `.sha256` file.

**Updating:** quit S-Display (use **Turn All On & Quit** if a display is off), replace the app in Applications, open it again.

## Using it

Each connected display gets a card in the menu:

- **Switch**: turns the display off. S-Display never turns off the last visible display.
  Turned-off displays are listed under **Turned off** with a **Turn On** button.
- **Screen size** (the `27" ▾` next to the resolution): some monitors report the wrong size.
  Pick the real diagonal so PPI and the **Recommended** size are right.
- **UI size slider**: every HiDPI size macOS offers for that display, from the largest text (left)
  to the most space (right). It applies when you release the knob. **Recommended** picks about
  110 points per inch, what macOS aims for on external displays (looks like 2560×1440 on 27").
- **Flexible HiDPI → Enable…**: adds a size every 16 points, from native down to half
  (81 sizes on a 1440p panel, 121 on 4K). macOS asks for your administrator password; the display blinks
  for about a second while it reloads. **Disable…** removes them again.

| Keys  | Action                                 |
|-------|----------------------------------------|
| ⌃⌥⌘0  | Turn all displays on                   |
| ⌃⌥⌘B  | Turn off the display under the pointer |

Hotkeys need no Accessibility permission. **Quit** leaves turned-off displays off; **Turn All On & Quit**
turns them back on first. With **Keep turned-off displays off after restart**, S-Display turns remembered
displays off again when it launches.

### Which size should I pick?

macOS draws HiDPI at exactly 2× the "looks like" size and then fits that onto the panel.
Sizes that fit with a whole ratio are pixel-perfect:

| Panel | Pixel-perfect sizes | Notes |
|---|---|---|
| 1440p (e.g. 27" 2560×1440) | 1280×720 (1:1), **2560×1440 (2:1)** | Sizes in between are scaled by a fraction and look softer on ~109 PPI panels. |
| 4K (3840×2160) | **1920×1080 (1:1)**, 3840×2160 | At ~140–160 PPI fractional sizes such as 2560×1440 still look sharp. |

For bigger text without losing sharpness, keep a pixel-perfect size and enlarge text in apps
(⌘+, or System Settings → Accessibility → Display → Text size).

## Getting a display back

- S-Display running: **Turn On** in the menu, or press ⌃⌥⌘0.
- S-Display not running: open S-Display, or unplug and replug the display's cable, or restart the Mac.
- Nothing lit at all (e.g. the other monitor was unplugged while S-Display wasn't running):
  replug the turned-off display's cable, or hold the power button to restart.

If a Flexible HiDPI override misbehaves, remove it and replug the cable (or restart):

```bash
sudo rm /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>
```

## Uninstall

1. In S-Display, click **Disable…** on every display with Flexible HiDPI on, then **Turn All On & Quit**.
2. Delete `/Applications/S-Display.app`.
3. Optional: `defaults delete com.huyly.sdisplay` and remove `~/Library/Application Support/S-Display`.

## Privacy and safety

- No networking code: S-Display never connects to the internet.
- It uses private macOS APIs (SkyLight, CoreDisplay) to turn displays off and reach hidden display modes.
  They are loaded at runtime, so if a macOS update removes one the matching feature disappears instead of the app crashing.
- The only thing written as root is the display override file, after you enter your password. See [SECURITY.md](SECURITY.md).
- It is not sandboxed, which is also why it cannot be on the Mac App Store.

S-Display is provided as is, without warranty (see [LICENSE](LICENSE)).

## Development

```bash
brew install xcodegen   # once
make run                # generate the Xcode project, build and launch "S-Display Dev"
make test               # unit tests (pure logic only; they never touch your displays)
make install            # Release build copied to /Applications
make release            # dist/S-Display-<version>.dmg, .zip and .sha256, like the GitHub release
make probe              # read-only report: displays, HiDPI sizes, override files
make icon               # re-render the app icon (scripts/make-icon.swift)
make logs               # live log stream
```

`S-Display.xcodeproj` is generated from `project.yml`. Debug builds are called **S-Display Dev**
(`com.huyly.sdisplay.dev`), so they keep their own settings and never touch the installed app's.
To sign with your Apple Development certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
and set your Team ID.

Debug builds also accept commands from `scripts/debug-command.swift`, which drives the same code paths as the menu
and prints the app's state from the log:

```bash
swift scripts/debug-command.swift dump              # displays, HiDPI stops (* = SkyLight-only), records
swift scripts/debug-command.swift off 4             # also: on 4 | all-on | size 4 2304
WAIT=300 swift scripts/debug-command.swift hidpi-install 4   # waits for the password prompt
swift scripts/debug-command.swift blink 4           # soft reconnect; strand 4 rehearses a crash mid-blink
```

`<display>` is the display ID shown by `dump` or `make probe`, its UUID, or its name.

### Releasing

**Actions → Release → Run workflow** on `main`, pick patch / minor / major. The workflow works out the
next version from the latest `v*` tag, runs the tests, builds on GitHub's machines, attests the build and
publishes the DMG, ZIP and checksums with generated release notes. CI runs the tests and builds on every
pull request and push to `main`.

### How it works

| Feature | Mechanism |
|---|---|
| Turn off / on | SkyLight `SLSConfigureDisplayEnabled` in a `CGBeginDisplayConfiguration` transaction completed `.permanently`; disabled displays are found again through `SLSGetDisplayList`. |
| Confirmation | WindowServer's result codes can be wrong both ways, so every operation waits for the display reconfiguration callback to show the new state (no polling, 5–8 s timeout, no automatic retries). |
| Safety | Last-visible-display guard; other displays' modes restored if macOS moves them; if nothing visible is left for 5 s (20 s right after a wake, never while asleep), everything is turned back on. |
| UI size | CoreGraphics modes plus HiDPI modes only SkyLight lists (a 1440p panel natively has looks-like 1600, 1920 and 2560 HiDPI hidden this way), applied with `CGConfigureDisplayWithDisplayMode` or `CGSConfigureDisplayMode`. |
| Flexible HiDPI | `scale-resolutions` override at `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x`, written as root via AppleScript, then a soft reconnect (off, then on) so macOS rebuilds the mode list. A marker in UserDefaults covers the blink: if S-Display dies with the display off, the next launch turns it back on (`.forAppOnly` doesn't do this on macOS 27; a display disabled that way stays off after the process dies). A file S-Display didn't write is backed up to `~/Library/Application Support/S-Display/OverrideBackups` and restored on Disable. |

Private symbols are resolved with `dlsym`, so if a macOS update removes one, the matching feature is hidden
instead of the app crashing. The app is not sandboxed and isn't meant for the App Store.

## Credits

Approach and several details come from [Crisp](https://github.com/didriksg/Crisp) by Didrik Galteland,
especially its measured notes in `docs/display-notes.md`. Adapted parts: the smooth-scaling ladder and
override encoding, the privileged-command helper, the `CGSDisplayModeDescription` layout, and the
disconnect / soft-reconnect / mode-restore ideas. Also inspired by
[Lunar](https://github.com/alin23/Lunar) and [BetterDisplay](https://github.com/waydabber/BetterDisplay).

Crisp's license applies to those adapted parts:

```
MIT License

Copyright (c) 2026 Didrik Galteland

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
