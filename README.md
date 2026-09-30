# S-Display

A small macOS menu bar app with two display tools:

- **BlackOut** – turn a display fully off. It leaves the layout, windows move to the remaining displays,
  the panel gets no signal and the GPU stops drawing it. Works like Lunar's BlackOut / BetterDisplay's Disconnect.
- **Flexible HiDPI** – sharp (Retina-style) scaling on 1440p and 4K monitors, with a slider for how large
  text and UI look. Works like BetterDisplay's Flexible Scaling.

Requires an Apple Silicon Mac and macOS 14 or later. Built and tested on macOS 27 (M5 Pro).

## Build and run

```sh
brew install xcodegen   # once
make run                # generate the Xcode project, build Debug, launch
make test               # unit tests (pure logic only; they never touch your displays)
make install            # Release build copied to /Applications (best for Launch at login)
make probe              # read-only report: displays, HiDPI sizes, override files
make icon               # re-render the app icon (scripts/make-icon.swift)
make logs               # live log stream
```

`S-Display.xcodeproj` is generated from `project.yml`; open it in Xcode after `make gen` if you prefer.

## Using it

Click the display icon in the menu bar. Each display gets a card:

- **Switch** – turns the display off. S-Display refuses to turn off the last visible display.
  Turned-off displays are listed under **Turned off** with a **Turn On** button.
- **UI size slider** – every HiDPI size macOS offers for that panel, from the largest text (left) to the
  most space (right). It applies when you release the knob. **Recommended** picks about 110 points per inch,
  which is what macOS aims for on external displays (looks like 2560×1440 on a 27" panel).
- **Flexible HiDPI → Enable…** (and **Disable…** to undo) – adds a dense ladder of HiDPI sizes (every 16 points from native down to half:
  81 sizes on a 1440p panel, 121 on 4K). macOS asks for your administrator password once; the display then
  blinks for about a second while it reloads. A 1x mode is moved to the HiDPI mode of the same size:
  same UI size, sharper text.

Hotkeys (no Accessibility permission needed):

| Keys  | Action                                   |
|-------|------------------------------------------|
| ⌃⌥⌘0  | Turn all displays on                     |
| ⌃⌥⌘B  | Turn off the display under the pointer   |

**Quit** leaves turned-off displays off. **Turn All On & Quit** turns them back on first.
With **Keep turned-off displays off after restart**, S-Display turns remembered displays off again when it launches.

## Getting a display back

- S-Display running: **Turn On** in the menu, or ⌃⌥⌘0.
- S-Display not running: open S-Display, or unplug and replug the display's cable, or restart the Mac.
- Nothing lit at all (e.g. the other monitor was unplugged while S-Display wasn't running):
  replug the turned-off display's cable, or hold the power button to restart.

If a Flexible HiDPI override misbehaves, remove it and replug the cable (or restart):

```sh
sudo rm /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>
```

`make probe` prints the exact path for each connected display.

## How it works

| Feature | Mechanism |
|---|---|
| Turn off / on | SkyLight `SLSConfigureDisplayEnabled` in a `CGBeginDisplayConfiguration` transaction completed `.permanently`; disabled displays are found again through `SLSGetDisplayList`. |
| Confirmation | WindowServer's result codes can be wrong both ways, so every operation waits for the display reconfiguration callback to show the new state (no polling, 5–8 s timeout, no automatic retries). |
| Safety | Last-visible-display guard; other displays' modes restored if macOS moves them; if nothing visible is left, everything is turned back on. |
| UI size | CoreGraphics modes plus HiDPI modes only SkyLight lists (a 1440p panel natively has looks-like 1600, 1920 and 2560 HiDPI hidden this way), applied with `CGConfigureDisplayWithDisplayMode` or `CGSConfigureDisplayMode`. |
| Flexible HiDPI | `scale-resolutions` override at `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x`, written as root via AppleScript, then a soft reconnect (off, then on) so macOS rebuilds the mode list. A marker in UserDefaults covers the blink: if S-Display dies with the display off, the next launch turns it back on (`.forAppOnly` doesn't do this on macOS 27; a display disabled that way stays off after the process dies). A file S-Display didn't write is backed up to `~/Library/Application Support/S-Display/OverrideBackups` and restored on Remove. |

Private symbols are resolved with `dlsym`, so if a macOS update removes one, the matching feature is hidden
instead of the app crashing. The app is not sandboxed and isn't meant for the App Store.

## Development

Debug builds accept commands from `scripts/debug-command.swift`, which runs the same code paths as the menu
and prints the app's state from the log:

```sh
swift scripts/debug-command.swift dump              # displays, HiDPI stops (* = SkyLight-only), records
swift scripts/debug-command.swift off 4             # also: on 4 | all-on | size 4 2304
WAIT=300 swift scripts/debug-command.swift hidpi-install 4   # waits for the password prompt
swift scripts/debug-command.swift blink 4           # soft reconnect; strand 4 rehearses a crash mid-blink
```

`<display>` is the display ID shown by `dump` or `make probe`, its UUID, or its name.

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
