#!/bin/sh
# The Codex plugin's run.sh yields to hooks.json only when Codex really loads it
# (review, 27.10). Fake HOME and CODEX_HOME; the hook program is a stub that
# leaves a marker. Run from the repo root: sh tools/codex-plugin-test.sh
set -u
root=$(pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cpt.XXXXXX")
fail=0
HOME_=$tmp/home; CH=$tmp/codex
mkdir -p "$HOME_/.cloudingbar" "$CH"
cat > "$HOME_/.cloudingbar/cloudingbar-hook" <<STUB
#!/bin/sh
echo ran >> "$tmp/marker"
STUB
chmod +x "$HOME_/.cloudingbar/cloudingbar-hook"

good='{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"'$HOME_'/.cloudingbar/cloudingbar-hook --codex"}]}]}}'
bad='{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"x/cloudingbar-hook --codex"},]}]}}'

# run <name> <expect: ran|quiet>  (hooks.json and config.toml already in place)
run() {
  rm -f "$tmp/marker"
  HOME=$HOME_ CODEX_HOME=$CH sh "$root/codex-plugin/hooks/run.sh" PreToolUse </dev/null >/dev/null 2>&1
  if [ -f "$tmp/marker" ]; then got=ran; else got=quiet; fi
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $got)"; fail=1; fi
}

rm -f "$CH/hooks.json" "$CH/config.toml"
run "no hooks.json: plugin works" ran
printf '%s' "$good" > "$CH/hooks.json"
run "working Connect: plugin stays quiet" quiet
printf '%s' "$bad" > "$CH/hooks.json"
run "broken JSON (extra comma): plugin works" ran
printf '%s' "$good" > "$CH/hooks.json"
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\nenabled = false\n' "$CH" > "$CH/config.toml"
run "our hook switched off for this event: plugin works" ran
printf '[hooks.state."%s/hooks.json:stop:0:0"]\nenabled = false\n' "$CH" > "$CH/config.toml"
run "another event switched off: plugin stays quiet" quiet
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\nenabled = true\n' "$CH" > "$CH/config.toml"
run "state enabled = true: plugin stays quiet" quiet

rm -rf "$tmp"
exit $fail
