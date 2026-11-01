#!/usr/bin/env python3
"""The table for `make coverage` from two `llvm-cov export -summary-only` files:
what the checks ran (reached), and every line of the Mac app (whole)."""
import json
import os
import sys


def lines_by_file(path):
    """{path relative to here: (executable lines, covered lines)} for Sources/ only."""
    with open(path) as f:
        data = json.load(f)
    out = {}
    for export in data["data"]:
        for entry in export["files"]:
            rel = os.path.relpath(entry["filename"])
            if rel.startswith("Sources/"):
                lines = entry["summary"]["lines"]
                out[rel] = (lines["count"], lines["covered"])
    return out


def percent(covered, count):
    return 100.0 * covered / count if count else 100.0


def main():
    reached = lines_by_file(sys.argv[1])
    whole = lines_by_file(sys.argv[2])
    rows = []
    for name in sorted(set(reached) | set(whole)):
        if name in reached:
            count, covered = reached[name]
            rows.append((name, count, covered, True))
        else:
            rows.append((name, whole[name][0], 0, False))

    width = max(len(r[0]) for r in rows) + 2
    print("%-*s %7s %7s %10s" % (width, "file", "lines", "missed", "cover"))
    for name, count, covered, built in rows:
        cover = "%.1f%%" % percent(covered, count) if built else "not built"
        print("%-*s %7d %7d %10s" % (width, name, count, count - covered, cover))

    built = [r for r in rows if r[3]]
    built_count = sum(r[1] for r in built)
    built_covered = sum(r[2] for r in built)
    all_count = sum(r[1] for r in rows)
    print()
    print("In the test build: %.1f%% (%d of %d lines, %d files)"
          % (percent(built_covered, built_count), built_covered, built_count, len(built)))
    print("Of all the Mac code: %.1f%% (%d of %d lines, %d files)"
          % (percent(built_covered, all_count), built_covered, all_count, len(rows)))


if __name__ == "__main__":
    main()
