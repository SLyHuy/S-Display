#!/usr/bin/env bash
# Installs a pinned XcodeGen release after checking its SHA-256. Used by CI so that
# release builds never depend on whatever version a package manager serves that day.
#
# To upgrade: set the new version and the SHA-256 of its xcodegen.zip, e.g.
#   gh api repos/yonaskolb/XcodeGen/releases/tags/<version> --jq '.assets[] | select(.name=="xcodegen.zip") | .digest'
# then check that `xcodegen generate` still produces the same project.
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

DEST="${1:-${RUNNER_TEMP:-/tmp}/xcodegen-$XCODEGEN_VERSION}"
ZIP="$DEST/xcodegen.zip"

mkdir -p "$DEST"
curl -sSfL -o "$ZIP" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $ZIP" | shasum -a 256 -c -
unzip -q -o "$ZIP" -d "$DEST"
"$DEST/xcodegen/bin/xcodegen" --version

# On GitHub Actions, make it available to the following steps.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$DEST/xcodegen/bin" >> "$GITHUB_PATH"
fi
