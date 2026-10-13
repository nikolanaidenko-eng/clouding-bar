APP = ClaudeBar
BUNDLE = build/$(APP).app
BINARY = build/$(APP)
SOURCES = $(wildcard Sources/ClaudeBar/*.swift)
# Pin the deployment target: newer Command Line Tools otherwise stamp the
# binary with their own SDK's macOS version and it won't launch on older ones.
TARGET = $(shell uname -m)-apple-macosx12.0
# A stable signing identity keeps the Accessibility permission across
# rebuilds (ad-hoc signatures change every build, so macOS forgets it).
# Created once by `make signing-identity`; ad-hoc is the fallback.
SIGN_KEYCHAIN = $(HOME)/.claudebar/signing.keychain-db
SIGN_IDENTITY = ClaudeBar Local Signing

.PHONY: all build bundle install clean signing-identity

all: bundle

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
	@if [ -f "$(SIGN_KEYCHAIN)" ]; then \
		security unlock-keychain -p "" "$(SIGN_KEYCHAIN)" && \
		codesign --force --keychain "$(SIGN_KEYCHAIN)" --sign "$(SIGN_IDENTITY)" $(BUNDLE) && \
		echo "Signed with $(SIGN_IDENTITY)"; \
	else \
		codesign --force --sign - $(BUNDLE) 2>/dev/null || true; \
		echo "Signed ad-hoc (run 'make signing-identity' to keep Accessibility across rebuilds)"; \
	fi
	@echo "Built $(BUNDLE)"

install: bundle
	./install.sh

signing-identity:
	./packaging/make-signing-identity.sh "$(SIGN_KEYCHAIN)" "$(SIGN_IDENTITY)"

clean:
	rm -rf .build build
