#!/usr/bin/env bash
# Syncs SLyHuy/homebrew-tap (Casks/s-display.rb) to the latest GitHub Release of SLyHuy/S-Display.
# Uses your local `gh` authentication — no PAT secret needs to be stored in GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in gh jq ruby base64; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required" >&2; exit 1; }
done

RELEASE_REPO="SLyHuy/S-Display"
TAP_REPO="SLyHuy/homebrew-tap"
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

echo "==> Checking $TAP_REPO/$CASK_PATH"
gh api "repos/$TAP_REPO/contents/$CASK_PATH" > "$TMP_DIR/cask.json"
FILE_SHA=$(jq -r .sha "$TMP_DIR/cask.json")
if ! [[ "$FILE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid blob SHA from $TAP_REPO" >&2
  exit 1
fi

jq -r .content "$TMP_DIR/cask.json" | tr -d '\n' | base64 --decode > "$TMP_DIR/orig.rb"
cp "$TMP_DIR/orig.rb" "$TMP_DIR/updated.rb"

./scripts/update-homebrew-cask.sh "$VERSION" "$SHA256" "$TMP_DIR/updated.rb"

if cmp -s "$TMP_DIR/orig.rb" "$TMP_DIR/updated.rb"; then
  echo "==> $TAP_REPO is already up to date at v$VERSION"
  exit 0
fi

diff -u "$TMP_DIR/orig.rb" "$TMP_DIR/updated.rb" || true

UPDATED_B64=$(base64 < "$TMP_DIR/updated.rb" | tr -d '\n')
jq -n \
  --arg message "s-display $VERSION" \
  --arg content "$UPDATED_B64" \
  --arg sha "$FILE_SHA" \
  --arg branch "main" \
  '{message: $message, content: $content, sha: $sha, branch: $branch}' > "$TMP_DIR/payload.json"

gh api --method PUT "repos/$TAP_REPO/contents/$CASK_PATH" --input "$TMP_DIR/payload.json" >/dev/null
echo "==> Updated $TAP_REPO/$CASK_PATH to v$VERSION ($SHA256)"

