#!/bin/bash
# `make coverage`: what the checks in tools/coretest actually reach, file by
# file, and as a share of ALL the Mac code. The checks build only part of it,
# so a percent of that part alone says too much: the whole app is built too
# (never run), to count the lines nothing in the checks can reach.
#
# Out: the table on stdout, build/coverage/report.txt, and llvm-cov's own view
# of a file with: xcrun llvm-cov show build/coverage/coretest \
#   -instr-profile build/coverage/all.profdata <file>
# The exit status is the checks': a failed check still prints the table.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=build/coverage
HOME_FOR_TESTS=build/test-home-coverage
TARGET="$(uname -m)-apple-macosx12.0"
FLAGS=(-profile-generate -profile-coverage-mapping -target "$TARGET")
rm -rf "$OUT" "$HOME_FOR_TESTS"
mkdir -p "$OUT/raw" "$OUT/helpers" "$HOME_FOR_TESTS"

# What `make test` builds (the Makefile says; one list, never two).
read -r -a TEST_SOURCES <<< "$(make -s print-test-sources)"

echo "Building the checks and the helpers with counters…"
swiftc "${FLAGS[@]}" "${TEST_SOURCES[@]}" -o "$OUT/coretest"
swiftc "${FLAGS[@]}" Sources/CloudingBarTap/*.swift -o "$OUT/helpers/cloudingbar-tap"
swiftc "${FLAGS[@]}" Sources/CloudingBarHook/*.swift Sources/CloudingBar/Core/Git.swift \
  Sources/CloudingBar/Core/SessionTitle.swift -o "$OUT/helpers/cloudingbar-hook"

echo "Building the whole app, to count its lines (it isn't run)…"
swiftc "${FLAGS[@]}" Sources/CloudingBar/*.swift Sources/CloudingBar/*/*.swift \
  -Xlinker -weak_framework -Xlinker FoundationModels -o "$OUT/app"
swiftc "${FLAGS[@]}" Sources/CloudingBarKey/*.swift -o "$OUT/helpers/cloudingbar-key"

echo "Running the checks…"
status=0
LLVM_PROFILE_FILE="$PWD/$OUT/raw/%p.profraw" CLOUDINGBAR_DIR="$HOME_FOR_TESTS" CLOUDINGBAR_PLUGIN=plugin \
  CLOUDINGBAR_TEST_HELPERS="$OUT/helpers" "$OUT/coretest" > "$OUT/checks.txt" 2>&1 || status=$?
grep -E '^FAIL|failed$|all passed$' "$OUT/checks.txt" || true

xcrun llvm-profdata merge -sparse "$OUT"/raw/*.profraw -o "$OUT/all.profdata"
# Reached: from what ran. Lines of the rest: from the whole app, which ran never.
xcrun llvm-cov export -summary-only -instr-profile "$OUT/all.profdata" "$OUT/coretest" \
  -object "$OUT/helpers/cloudingbar-tap" -object "$OUT/helpers/cloudingbar-hook" > "$OUT/reached.json" 2>/dev/null
xcrun llvm-cov export -summary-only -instr-profile "$OUT/all.profdata" "$OUT/app" \
  -object "$OUT/helpers/cloudingbar-key" > "$OUT/whole.json" 2>/dev/null

python3 tools/coverage/report.py "$OUT/reached.json" "$OUT/whole.json" | tee "$OUT/report.txt"
exit "$status"
