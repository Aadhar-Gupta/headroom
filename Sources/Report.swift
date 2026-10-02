import Foundation

/// Plain-text report (`Headroom --dump`) and a demo snapshot of a Mac that's short on memory (`--demo`).
enum Report {
    private static func col(_ b: UInt64) -> String {
        let t = Fmt.bytes(b)
        return String(repeating: " ", count: max(0, 8 - t.count)) + t
    }

    static func text(_ s: Snapshot) -> String {
        var out = [String]()
        let m = s.memory
        out.append("\(s.health.headline)")
        out.append(s.summary)
        out.append("Used \(Fmt.bytes(m.used)) of \(Fmt.ram(m.total)) · swap \(Fmt.bytes(m.swapUsed)) · \(m.freePercent)% free · pressure level \(m.pressureLevel) · apps want \(Fmt.bytes(s.demand))")
        out.append("")
        out.append("INSIGHTS")
        if s.insights.isEmpty { out.append("  Nothing needs attention") }
        for i in s.insights { out.append("  [\(i.severity)] \(i.title)\n      \(i.detail)  {\(i.actions.map(\.title).joined(separator: " | "))}") }
        out.append("\nAPPS")
        for a in s.apps { out.append("  \(col(a.footprint))  \(a.name) (\(a.count))\(a.canQuit ? "  [quit]" : "")") }
        if s.otherBytes > 0 { out.append("  \(col(s.otherBytes))  Everything else (\(s.otherCount))") }
        out.append("\nCLAUDE CODE SESSIONS")
        for c in s.sessions {
            out.append("  \(col(c.own + c.children))  \(c.folder) · \(c.host) · open \(Fmt.duration(c.uptime)) (own \(Fmt.bytes(c.own)))\(c.activity.map { " — \($0)" } ?? "")")
        }
        out.append("\nDEV TOOLS")
        for r in s.devRuns {
            out.append("  \(col(r.footprint))  \(r.label) · \(r.folder) · \(r.launcher) · \(Fmt.duration(r.uptime)) · \(r.pids.count) procs\(r.isOrphan ? " · ORPHAN" : "")")
        }
        out.append("\nHEAVY BROWSER TABS")
        for t in s.tabs { out.append("  \(col(t.footprint))  \(t.browser) \(t.isExtension ? "extension" : "tab") · pid \(t.ref.pid) · open \(Fmt.duration(t.uptime))") }
        return out.joined(separator: "\n")
    }

    static var demo: Snapshot {
        let GB = Analyzer.GB, MB = Analyzer.MB
        func gb(_ x: Double) -> UInt64 { UInt64(x * Double(GB)) }
        let now = Date()
        func ref(_ pid: pid_t, _ ago: TimeInterval) -> PidRef { PidRef(pid: pid, start: now.addingTimeInterval(-ago)) }
        func run(_ pid: pid_t, _ label: String, _ kind: DevKind, _ folder: String, _ size: Double, _ procs: Int, _ ago: TimeInterval, claude: Bool = true) -> DevRun {
            DevRun(rootPID: pid, label: label, kind: kind, folder: folder,
                   launcher: claude ? "Claude" : "Terminal", viaClaude: claude, isOrphan: false,
                   footprint: gb(size), pids: (0..<procs).map { ref(pid + pid_t($0), ago) }, uptime: ago)
        }

        var s = Snapshot()
        s.memory = SystemMemory(total: 16 * GB, used: gb(15.4), swapUsed: gb(11.7), swapTotal: 16 * GB, freePercent: 33, pressureLevel: 2)
        s.demand = gb(26.7)
        func app(_ name: String, _ size: Double, _ count: Int) -> AppGroup {
            let path = "/Applications/\(name).app"
            return AppGroup(id: path, name: name, bundlePath: path, footprint: gb(size), count: count, canQuit: true)
        }
        s.apps = [
            app("Google Chrome", 6.85, 28),
            app("Visual Studio Code", 2.34, 18),
            app("Claude", 2.28, 15),
            app("Docker", 1.9, 6),
            app("Slack", 1.1, 7),
            AppGroup(id: "WindowServer", name: "WindowServer", bundlePath: nil, footprint: 350 * MB, count: 1),
            AppGroup(id: "/System/Library/CoreServices/Spotlight.app", name: "Spotlight", bundlePath: "/System/Library/CoreServices/Spotlight.app", footprint: 260 * MB, count: 1),
        ]
        s.otherBytes = gb(1.6)
        s.otherCount = 412
        let claude = "/Applications/Claude.app"
        s.sessions = [
            CodeSession(pid: 51807, host: "Claude", hostBundle: claude, folder: "storefront", uptime: 6800, own: 375 * MB, children: gb(6.2), activity: "running jest --selectProjects web · 2.3 GB"),
            CodeSession(pid: 13346, host: "Claude", hostBundle: claude, folder: "storefront", uptime: 15600, own: 265 * MB, children: 0, activity: nil),
            CodeSession(pid: 45832, host: "Claude", hostBundle: claude, folder: "api-server", uptime: 11400, own: 236 * MB, children: 0, activity: nil),
            CodeSession(pid: 67027, host: "Claude", hostBundle: claude, folder: "No folder", uptime: 4400, own: 185 * MB, children: 0, activity: nil),
        ]
        s.devRuns = [
            run(41306, "jest --selectProjects web", .test, "storefront › checkout", 2.3, 4, 290),
            run(41454, "jest src/cart", .test, "storefront › cart-fix", 2.1, 3, 310),
            run(42480, "tsc --noEmit", .typecheck, "storefront › search", 1.86, 2, 250),
            run(39508, "jest src/auth", .test, "storefront › login", 0.9, 3, 330),
            run(58261, "yarn dev", .server, "docs/site", 0.25, 6, 101_000, claude: false),
        ]
        s.tabs = [
            BrowserTab(ref: ref(27841, 176_000), browser: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", isExtension: false, footprint: gb(1.41), uptime: 176_000),
            BrowserTab(ref: ref(10279, 202_000), browser: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", isExtension: false, footprint: 853 * MB, uptime: 202_000),
        ]
        return Analyzer.finish(s)
    }
}
