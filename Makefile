PROJECT     := S-Display.xcodeproj
SCHEME      := S-Display
DERIVED     := build/DerivedData
DEBUG_APP   := $(DERIVED)/Build/Products/Debug/S-Display Dev.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/S-Display.app
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'
# Show only problems and the result; pipefail keeps xcodebuild's exit status.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c
FILTER      := grep -E 'error:|warning:|✘|Test run|\*\* (BUILD|TEST)' | grep -v appintentsmetadataprocessor

.PHONY: gen build run test install release icon probe logs clean

gen:
	xcodegen generate --quiet

# Debug build ("S-Display Dev", bundle id com.huyly.sdisplay.dev): its own preferences,
# so it never touches the installed app's settings.
build: gen
	$(XCODEBUILD) -configuration Debug build 2>&1 | $(FILTER)

# Quitting S-Display leaves turned-off displays off; use "Turn All On & Quit" to restore them.
run: build
	-pkill -x "S-Display Dev"
	open "$(DEBUG_APP)"

test: gen
	$(XCODEBUILD) -configuration Debug test 2>&1 | $(FILTER)

# Release build copied to /Applications and launched.
install: gen
	$(XCODEBUILD) -configuration Release build 2>&1 | $(FILTER)
	-pkill -x S-Display
	rm -rf /Applications/S-Display.app
	ditto "$(RELEASE_APP)" /Applications/S-Display.app
	open /Applications/S-Display.app

# Same packaging as the GitHub release: dist/S-Display-<version>.dmg, .zip and .sha256.
release:
	./scripts/release.sh

# Re-renders the app icon from scripts/make-icon.swift into the asset catalog.
icon:
	swift scripts/make-icon.swift

# Read-only: lists displays, HiDPI stops and override files.
probe:
	swift scripts/probe-displays.swift

logs:
	/usr/bin/log stream --style compact --predicate 'subsystem == "com.huyly.sdisplay"'

clean:
	rm -rf build dist $(PROJECT)
