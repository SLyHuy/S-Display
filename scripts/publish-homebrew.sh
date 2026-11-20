#!/usr/bin/env bash
# Syncs SLyHuy/homebrew-tap (Casks/s-display.rb) to the latest GitHub Release of SLyHuy/S-Display.
# Reads release metadata via `gh` and pushes a signed commit over SSH — no PAT secret needed.
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in gh jq ruby git; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

RELEASE_REPO="SLyHuy/S-Display"
TAP_REMOTE="git@github.com:SLyHuy/homebrew-tap.git"
CASK_PATH="Casks/s-display.rb"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Checking latest release on $RELEASE_REPO"
gh api "repos/$RELEASE_REPO/releases/latest" > "$TMP_DIR/release.json"

TAG=$(jq -r .tag_name "$TMP_DIR/release.json")
VERSION="${TAG#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected latest release tag: $TAG" >&2
  exit 1
fi

DIGEST=$(jq -r --arg name "S-Display-$VERSION.dmg" \
  '.assets[] | select(.name == $name) | .digest // empty' "$TMP_DIR/release.json")
SHA256="${DIGEST#sha256:}"
if ! [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Could not read SHA-256 digest for S-Display-$VERSION.dmg from release $TAG" >&2
  exit 1
fi

echo "==> Cloning SLyHuy/homebrew-tap"
TAP_DIR="$TMP_DIR/homebrew-tap"
git clone --quiet --depth 1 --branch main "$TAP_REMOTE" "$TAP_DIR"

./scripts/update-homebrew-cask.sh "$VERSION" "$SHA256" "$TAP_DIR/$CASK_PATH"

cd "$TAP_DIR"
if git diff --quiet -- "$CASK_PATH"; then
  echo "==> SLyHuy/homebrew-tap is already up to date at v$VERSION"
  exit 0
fi

git --no-pager diff -- "$CASK_PATH"
git add -- "$CASK_PATH"
git commit -S -m "s-display $VERSION"
git push origin HEAD:main
echo "==> Updated SLyHuy/homebrew-tap/$CASK_PATH to v$VERSION ($SHA256)"
