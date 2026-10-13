APP = ClaudeBar
BUNDLE = build/$(APP).app
BINARY = build/$(APP)
SOURCES = $(wildcard Sources/ClaudeBar/*.swift)

.PHONY: all build bundle install clean

all: bundle

# Plain swiftc keeps the build working even on minimal Command Line Tools
# installs (some are missing SwiftPM's manifest module). `swift build`
# works too if your toolchain is happy — see Package.swift.
build: $(SOURCES)
	mkdir -p build
	swiftc -O $(SOURCES) -o $(BINARY)

# Wrap the binary in a minimal .app bundle. macOS ties the Accessibility
# permission to the bundle, so this beats a bare binary.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp packaging/Info.plist $(BUNDLE)/Contents/
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/
	codesign --force --sign - $(BUNDLE) 2>/dev/null || true
	@echo "Built $(BUNDLE)"

install: bundle
	./install.sh

clean:
	rm -rf .build build
