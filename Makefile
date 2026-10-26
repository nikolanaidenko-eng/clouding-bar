# The app, its helpers (hook, tap, key keeper), checks and pictures — all
# with plain swiftc. `make` builds, `make install` puts it in place.
APP = CloudingBar
BINARY = build/$(APP)
BUNDLE = $(BINARY).app
SOURCES = $(wildcard Sources/CloudingBar/*.swift Sources/CloudingBar/*/*.swift)
TAP = build/cloudingbar-tap
TAP_SOURCES = $(wildcard Sources/CloudingBarTap/*.swift)
HOOK = build/cloudingbar-hook
HOOK_SOURCES = $(wildcard Sources/CloudingBarHook/*.swift) Sources/CloudingBar/Core/Git.swift
KEY = build/cloudingbar-key
KEY_SOURCES = $(wildcard Sources/CloudingBarKey/*.swift)
# Pin the deployment target: newer Command Line Tools otherwise stamp the
# binary with their own SDK's macOS version and it won't launch on older ones.
TARGET = $(shell uname -m)-apple-macosx12.0
# A stable signing identity keeps the Accessibility permission across
# rebuilds (ad-hoc signatures change every build, so macOS forgets it).
# packaging/sign.sh picks an "Apple Development" certificate from your
# keychain (added in Xcode → Settings → Accounts), then the self-signed one
# created by `make signing-identity`, then ad-hoc.

.PHONY: all build bundle install clean signing-identity snapshots test release icon demo

all: bundle $(TAP) $(HOOK)

# swiftc straight, not SwiftPM: some Command Line Tools installs lack the
# manifest module `swift build` needs (Package.swift is there for editors).
# Apple's on-device model (macOS 26) linked weakly: macOS 12-25 start without it.
WEAK = -Xlinker -weak_framework -Xlinker FoundationModels

build: $(SOURCES)
	@mkdir -p build
	swiftc -O -target $(TARGET) $(SOURCES) $(WEAK) -o $(BINARY)

# The .app: macOS grants Accessibility to an app bundle (and keeps it across
# rebuilds while the signature's identity stays the same), not a bare binary.
bundle: build $(KEY) $(TAP) $(HOOK)
	@rm -rf $(BUNDLE) && mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources/hooks
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/
	cp packaging/Info.plist $(BUNDLE)/Contents/
	cp packaging/AppIcon.icns $(BUNDLE)/Contents/Resources/
	@# Already signed, and copied as is: its Keychain permission survives.
	cp -p $(KEY) $(BUNDLE)/Contents/MacOS/
	@# What the app puts in ~/.cloudingbar itself (Setup.swift), for a download.
	cp -p $(TAP) $(HOOK) $(BUNDLE)/Contents/MacOS/
	cp hooks/cloudingbar-statusline.sh hooks/cloudingbar-wrapper.sh $(BUNDLE)/Contents/Resources/hooks/
	@# The plugin, for the zip Settings → Cowork saves (the marketplace serves the same folder).
	cp -R plugin $(BUNDLE)/Contents/Resources/plugin
	@packaging/sign.sh $(BUNDLE)
	@echo "Built $(BUNDLE)"

# Keeps the claude.ai session key for the app. Built and signed only when
# its source changes: the Keychain remembers "Always Allow" per exact build
# when there's no Team ID, so a helper that stays the same keeps it.
$(KEY): $(KEY_SOURCES)
	mkdir -p build
	swiftc -O -target $(TARGET) $(KEY_SOURCES) -o $(KEY)
	@packaging/sign.sh $(KEY) dev.cloudingbar.key

# Helper for the VS Code extension's claudeProcessWrapper setting: copies
# Claude's stdout through and reports the session limit to Clouding Bar.
$(TAP): $(TAP_SOURCES)
	mkdir -p build
	swiftc -O -target $(TARGET) $(TAP_SOURCES) -o $(TAP)
	@packaging/sign.sh $(TAP) dev.cloudingbar.tap

# The hook command for every Claude Code hook event: forwards events to the
# app and waits for answers to permissions and questions (docs/protocol.md).
$(HOOK): $(HOOK_SOURCES)
	mkdir -p build
	swiftc -O -target $(TARGET) $(HOOK_SOURCES) -o $(HOOK)
	@packaging/sign.sh $(HOOK) dev.cloudingbar.hook

# In place, connected to Claude Code, opened (install.sh says how).
install: bundle
	@./install.sh

# A universal, Developer ID-signed, notarized .dmg (packaging/release.sh
# says what it needs once). DRY=1 make release: everything but the notary.
release:
	./packaging/release.sh

# docs/demo.gif for the README: the tour's scenes, recorded as they play
# (a small window shows in a corner of the screen for ~25 s).
demo:
	mkdir -p build docs
	swiftc -O -target $(TARGET) $(wildcard Sources/CloudingBar/Core/*.swift Sources/CloudingBar/TouchBar/*.swift Sources/CloudingBar/Widget/*.swift Sources/CloudingBar/Settings/*.swift) Sources/CloudingBar/AppModel.swift Sources/CloudingBar/Voice.swift Sources/CloudingBar/HotKeys.swift Sources/CloudingBar/KeySender.swift Sources/CloudingBar/DebugLog.swift tools/demo/Scenes.swift tools/demo/main.swift -o build/demo
	./build/demo docs/demo.gif

# The app icon (Cloud on a dark tile) → packaging/AppIcon.icns.
icon:
	mkdir -p build
	swiftc -target $(TARGET) tools/icon/main.swift -o build/icon
	./build/icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o packaging/AppIcon.icns

# Checks for the core: session picked by window title, hook output, config.
test: $(TAP)
	mkdir -p build
	swiftc -target $(TARGET) $(wildcard Sources/CloudingBar/Core/*.swift) Sources/CloudingBar/DebugLog.swift Sources/CloudingBar/HotKeys.swift Sources/CloudingBar/KeySender.swift Sources/CloudingBar/Setup.swift tools/coretest/main.swift -o build/coretest
	rm -rf build/test-home && mkdir -p build/test-home
	CLOUDINGBAR_DIR=build/test-home CLOUDINGBAR_PLUGIN=plugin ./build/coretest

# The Touch Bar in every mode as PNGs (build/snapshots), to compare with
# design/TB-*.dc.html. A separate tool; nothing here goes into the app.
snapshots:
	mkdir -p build
	swiftc -target $(TARGET) $(wildcard Sources/CloudingBar/Core/*.swift Sources/CloudingBar/TouchBar/*.swift Sources/CloudingBar/Widget/*.swift Sources/CloudingBar/Settings/*.swift) Sources/CloudingBar/AppModel.swift Sources/CloudingBar/Voice.swift Sources/CloudingBar/HotKeys.swift Sources/CloudingBar/KeySender.swift Sources/CloudingBar/DebugLog.swift tools/snapshot/main.swift -o build/tb-snapshot
	./build/tb-snapshot build/snapshots

signing-identity:
	./packaging/make-signing-identity.sh "$(HOME)/.cloudingbar/signing.keychain-db" "ClaudeBar Local Signing"

clean:
	rm -rf build .build
