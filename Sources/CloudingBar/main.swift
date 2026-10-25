import AppKit

// With --connect: link Claude Code to Clouding Bar — its hooks and status
// line in ~/.claude/settings.json, merged and backed up — then quit. The
// last step of install.sh for a build from source; a download asks at its
// first launch instead. Otherwise: the menu bar app, no Dock icon.
if CommandLine.arguments.dropFirst().contains("--connect") {
    do {
        try Setup.connect()
        print("  Claude Code connected: hooks and status line in ~/.claude/settings.json")
        if let vscode = Setup.describe(Setup.wrapVSCodeIfFree()) { print("  " + vscode) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("  Couldn't connect Claude Code: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
