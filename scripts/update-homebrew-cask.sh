#!/usr/bin/env bash
# Safely updates version and sha256 in a Homebrew Cask file (Casks/s-display.rb).
# Rejects symlinks, prevents version downgrades, validates Ruby syntax, and writes atomically.
# Usage: ./scripts/update-homebrew-cask.sh <version> <sha256> <cask-file>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <version> <sha256> <cask-file>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
CASK_FILE="$3"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 1
fi

if ! [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid sha256: $SHA256" >&2
  exit 1
fi

if [ -L "$CASK_FILE" ]; then
  echo "Refusing to modify symlink: $CASK_FILE" >&2
  exit 1
fi

if [ ! -f "$CASK_FILE" ]; then
  echo "Cask file not found: $CASK_FILE" >&2
  exit 1
fi

VERSION="$VERSION" SHA256="$SHA256" CASK_FILE="$CASK_FILE" ruby -e '
  path = ENV.fetch("CASK_FILE")
  version = ENV.fetch("VERSION")
  sha256 = ENV.fetch("SHA256")

  abort("Refusing to modify symlink: #{path}") if File.symlink?(path)
  content = File.read(path)

  current_version = content[/^\s*version\s+"([^"]+)"/, 1]
  abort("Could not find version stanza in #{path}") if current_version.nil?

  if Gem::Version.new(version) < Gem::Version.new(current_version)
    abort("Refusing to downgrade cask from #{current_version} to #{version}")
  end

  current_sha = content[/^\s*sha256\s+"([^"]+)"/, 1]
  abort("Could not find sha256 stanza in #{path}") if current_sha.nil?

  updated = content
    .sub(/^(\s*version\s+)"[^"]+"/) { "#{$1}\"#{version}\"" }
    .sub(/^(\s*sha256\s+)"[^"]+"/) { "#{$1}\"#{sha256}\"" }

  tmp_path = "#{path}.tmp.#{$$}"
  begin
    File.write(tmp_path, updated)
    unless system(RbConfig.ruby, "-c", tmp_path, out: File::NULL, err: File::NULL)
      abort("Syntax check failed for updated cask file")
    end
    File.rename(tmp_path, path)
  ensure
    File.unlink(tmp_path) if File.exist?(tmp_path)
  end
'
