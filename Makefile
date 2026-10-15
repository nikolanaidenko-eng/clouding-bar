APP = ClaudeBar
BUNDLE = build/$(APP).app
BINARY = build/$(APP)
SOURCES = $(wildcard Sources/ClaudeBar/*.swift)
TAP = build/claudebar-tap
TAP_SOURCES = $(wildcard Sources/ClaudeBarTap/*.swift)
# Pin the deployment target: newer Command Line Tools otherwise stamp the
# binary with their own SDK's macOS version and it won't launch on older ones.
TARGET = $(shell uname -m)-apple-macosx12.0
# A stable signing identity keeps the Accessibility permission across
# rebuilds (ad-hoc signatures change every build, so macOS forgets it).
# Preference: an "Apple Development" certificate from your keychain (added
# in Xcode → Settings → Accounts), then the self-signed one created by
# `make signing-identity`, then ad-hoc.
SIGN_KEYCHAIN = $(HOME)/.claudebar/signing.keychain-db
SIGN_IDENTITY = ClaudeBar Local Signing
APPLE_DEV_ID = $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $$2; exit}')

.PHONY: all build bundle install clean signing-identity

all: bundle $(TAP)

# Plain swiftc keeps the build working even on minimal Command Line Tools
# installs (some are missing SwiftPM's manifest module). `swift build`
# works too if your toolchain is happy — see Package.swift.
build: $(SOURCES)
	mkdir -p build
	swiftc -O -target $(TARGET) $(SOURCES) -o $(BINARY)

# Wrap the binary in a minimal .app bundle. macOS ties the Accessibility
# permission to the bundle, so this beats a bare binary.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp packaging/Info.plist $(BUNDLE)/Contents/
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/
	@# --timestamp=none: signing never talks to Apple's timestamp server.
	@if [ -n "$(APPLE_DEV_ID)" ]; then \
		codesign --force --timestamp=none --sign "$(APPLE_DEV_ID)" $(BUNDLE) && \
		echo "Signed with Apple Development ($(APPLE_DEV_ID))"; \
	elif [ -f "$(SIGN_KEYCHAIN)" ]; then \
		security unlock-keychain -p "" "$(SIGN_KEYCHAIN)" && \
		codesign --force --timestamp=none --keychain "$(SIGN_KEYCHAIN)" --sign "$(SIGN_IDENTITY)" $(BUNDLE) && \
		echo "Signed with $(SIGN_IDENTITY)"; \
	else \
		codesign --force --sign - $(BUNDLE) 2>/dev/null || true; \
		echo "Signed ad-hoc (run 'make signing-identity' to keep Accessibility across rebuilds)"; \
	fi
	@echo "Built $(BUNDLE)"

# Helper for the VS Code extension's claudeProcessWrapper setting: copies
# Claude's stdout through and reports the session limit to ClaudeBar.
$(TAP): $(TAP_SOURCES)
	mkdir -p build
	swiftc -O -target $(TARGET) $(TAP_SOURCES) -o $(TAP)

install: bundle $(TAP)
	./install.sh

signing-identity:
	./packaging/make-signing-identity.sh "$(SIGN_KEYCHAIN)" "$(SIGN_IDENTITY)"

clean:
	rm -rf .build build
