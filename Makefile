PROJECT     := S-Display.xcodeproj
SCHEME      := S-Display
DERIVED     := build/DerivedData
DEBUG_APP   := $(DERIVED)/Build/Products/Debug/S-Display.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/S-Display.app
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'
# Show only problems and the result; pipefail keeps xcodebuild's exit status.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c
FILTER      := grep -E 'error:|warning:|✘|Test run|\*\* (BUILD|TEST)' | grep -v appintentsmetadataprocessor

.PHONY: gen build run test release install icon probe logs clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCODEBUILD) -configuration Debug build 2>&1 | $(FILTER)

# Quitting S-Display leaves turned-off displays off; use "Turn all on & Quit" in the menu to restore them.
run: build
	-pkill -x S-Display
	open $(DEBUG_APP)

test: gen
	$(XCODEBUILD) -configuration Debug test 2>&1 | $(FILTER)

release: gen
	$(XCODEBUILD) -configuration Release build 2>&1 | $(FILTER)

install: release
	-pkill -x S-Display
	rm -rf /Applications/S-Display.app
	ditto $(RELEASE_APP) /Applications/S-Display.app
	open /Applications/S-Display.app

# Re-renders the app icon from scripts/make-icon.swift into the asset catalog.
icon:
	swift scripts/make-icon.swift

# Read-only: lists displays, HiDPI stops and override files.
probe:
	swift scripts/probe-displays.swift

logs:
	log stream --style compact --predicate 'subsystem == "com.slyhuy.SDisplay"'

clean:
	rm -rf build $(PROJECT)
