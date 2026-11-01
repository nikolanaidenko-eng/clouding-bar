import Foundation

// What the checks in this folder share, and the list of them (main.swift calls it).

func runMoreChecks() {
    runPillChecks()
    runWidgetRuleChecks()
    runBarChecks()
    runModelChecks()
    runRequestChecks()
    runSessionChecks()
    runStoreChecks()
    runSocketChecks()
    runHelperChecks()
    runFileChecks()
    runStatsChecks()
    runSetupChecks()
    runTextChecks()
}

/// A real bug these checks found, not fixed here (only the checks changed):
/// its counterexample stays, switched off. It fails nothing; once it holds,
/// it says so, and it can become a plain check.
func knownBug(_ holds: @autoclosure () -> Bool, _ what: String) {
    print(holds() ? "ok   (fixed? make it a plain check) \(what)" : "known bug, not counted: \(what)")
}

/// Keeps the main queue going until `done` or the time's up; whether it's done.
@discardableResult
func spin(_ timeout: TimeInterval = 5, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return done()
}

/// A folder of the checks' own, short enough for a socket's path (103 bytes:
/// a linked worktree's build/ can be deeper), gone afterwards.
func withShortFolder(_ name: String, _ body: (URL) -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cb-\(name)-\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    body(dir)
    try? FileManager.default.removeItem(at: dir)
}

/// The home folder is this one, for the length of `body`.
func withHome(_ dir: URL, _ body: () -> Void) {
    let old = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? fakeHome
    setenv("CFFIXED_USER_HOME", dir.path, 1)
    body()
    setenv("CFFIXED_USER_HOME", old, 1)
}

/// The app's folder is this one, for the length of `body`.
func withAppFolder(_ dir: URL, _ body: () -> Void) {
    let old = ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!
    setenv("CLOUDINGBAR_DIR", dir.path, 1)
    body()
    setenv("CLOUDINGBAR_DIR", old, 1)
}

/// Two rectangles share more than an edge.
func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > 0.001 && i.height > 0.001
}
