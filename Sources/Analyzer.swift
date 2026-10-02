import Foundation

enum Health: Int, Comparable {
    case healthy, tight, critical

    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    var headline: String {
        switch self {
        case .healthy: "Memory is healthy"
        case .tight: "Memory is getting tight"
        case .critical: "Your Mac is short on memory"
        }
    }
}

enum DevKind {
    case test, typecheck, build, server, other
}

struct AppGroup: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    var footprint: UInt64
    var count: Int
    var canQuit = false
}

struct DevRun: Identifiable {
    var id: pid_t { rootPID }
    let rootPID: pid_t
    let label: String
    let kind: DevKind
    let folder: String
    let launcher: String
    let viaClaude: Bool
    let isOrphan: Bool
    let footprint: UInt64
    let pids: [PidRef]
    let uptime: TimeInterval
}

struct CodeSession: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let host: String
    let hostBundle: String?
    let folder: String
    let uptime: TimeInterval
    let own: UInt64
    let children: UInt64
    let activity: String?
}

struct BrowserTab: Identifiable {
    var id: pid_t { ref.pid }
    let ref: PidRef
    let browser: String
    let bundlePath: String
    let isExtension: Bool
    let footprint: UInt64
    let uptime: TimeInterval
}

enum Severity: Int {
    case info, warning, critical
}

enum ActionKind {
    case copyAgentNote
    case endRuns([DevRun])
    case endTab(BrowserTab)
}

struct InsightAction: Identifiable {
    let id = UUID()
    let title: String
    let kind: ActionKind
    var destructive = false
}

struct Insight: Identifiable {
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let bytes: UInt64
    var actions: [InsightAction] = []
}

struct Snapshot {
    var memory = SystemMemory()
    /// Sum of every readable process footprint — what apps are asking for, including what's compressed or swapped.
    var demand: UInt64 = 0
    var health = Health.healthy
    var summary = "Checking memory…"
    var apps: [AppGroup] = []
    var otherBytes: UInt64 = 0
    var otherCount = 0
    var sessions: [CodeSession] = []
    var devRuns: [DevRun] = []
    var tabs: [BrowserTab] = []
    var insights: [Insight] = []
    var takenAt = Date()

    var usedFraction: Double {
        memory.total > 0 ? min(1, Double(memory.used) / Double(memory.total)) : 0
    }
}

enum Analyzer {
    static let MB: UInt64 = 1 << 20
    static let GB: UInt64 = 1 << 30

    static let devExecutables: Set<String> = [
        "node", "bun", "deno", "npm", "npx", "yarn", "pnpm", "tsc", "esbuild", "java", "ruby", "go",
        "gradle", "watchman", "uvicorn", "gunicorn", "php", "dotnet", "cargo", "rustc",
    ]
    static let browsers: Set<String> = [
        "Google Chrome", "Google Chrome Canary", "Google Chrome Beta", "Chromium", "Brave Browser",
        "Microsoft Edge", "Arc", "Vivaldi", "Opera", "Dia",
    ]
    static let knownTools: [String: DevKind] = [
        "jest": .test, "vitest": .test, "mocha": .test, "playwright": .test, "cypress": .test, "pytest": .test,
        "tsc": .typecheck, "tsserver": .typecheck, "vue-tsc": .typecheck, "tsgo": .typecheck,
        "webpack": .build, "esbuild": .build, "rollup": .build, "turbo": .build, "nx": .build, "tsup": .build,
        "gradle": .build, "babel": .build, "metro": .build, "eslint": .build,
        "vite": .server, "next": .server, "nuxt": .server, "expo": .server, "storybook": .server,
        "nodemon": .server, "concurrently": .server, "uvicorn": .server, "gunicorn": .server,
    ]
    static let scriptRunners: Set<String> = ["npm", "npx", "yarn", "pnpm", "bun"]

    // MARK: Classification

    static func bundle(of path: String) -> (name: String, path: String)? {
        guard let r = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<r.lowerBound]) + ".app"
        let name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return (name, bundlePath)
    }

    /// The Claude Code engine — run by the Claude desktop apps for every Code session, or by the CLI.
    static func isEngine(_ p: Proc) -> Bool {
        let base = (p.path as NSString).lastPathComponent
        return (base == "claude" && (p.path.contains("/claude-code/") || bundle(of: p.path) == nil))
            || p.path.contains("/share/claude/versions/")
    }

    static func isDev(_ p: Proc) -> Bool {
        if let b = bundle(of: p.path) { return b.name == "Python" }
        let base = (p.path as NSString).lastPathComponent
        return devExecutables.contains(base) || base.hasPrefix("python") || base.hasPrefix("node")
    }

    static func toolName(_ token: String) -> String? {
        let base = ((token as NSString).lastPathComponent as NSString).deletingPathExtension
        if knownTools[base] != nil { return base }
        if let r = token.range(of: "/node_modules/", options: .backwards) {
            let rest = token[r.upperBound...].split(separator: "/")
            if let first = rest.first {
                let pkg = first.hasPrefix("@") && rest.count > 1 ? String(rest[1]) : String(first)
                if knownTools[pkg] != nil { return pkg }
            }
        }
        return nil
    }

    static func devLabel(args: [String], path: String) -> (String, DevKind) {
        // npm/yarn rewrite argv into one title string ("npm exec jest --x"), so split on spaces as well.
        let tokens = args.flatMap { $0.split(separator: " ").map(String.init) }
        for (i, token) in tokens.enumerated() {
            if token.contains("jest-worker") || token.hasSuffix("processChild.js") { return ("jest worker", .test) }
            if let tool = toolName(token), let kind = knownTools[tool] {
                // Skip "--flag=value" settings; what's being run (files, projects) is more telling.
                let extra = tokens.dropFirst(i + 1).filter { !$0.contains("=") }.prefix(2).map { ($0 as NSString).lastPathComponent }
                return (([tool] + extra).joined(separator: " ").truncated(36), kind)
            }
        }
        // Script runners: "yarn dev", "npm run start".
        for (i, token) in tokens.enumerated() {
            let base = (token as NSString).lastPathComponent
            guard scriptRunners.contains(base) else { continue }
            let rest = tokens.dropFirst(i + 1).filter { !$0.hasPrefix("-") }.prefix(2)
            let label = ([base] + rest).joined(separator: " ")
            let serverish = ["dev", "start", "serve", "watch"].contains { label.contains($0) }
            return (label.truncated(36), serverish ? .server : .other)
        }
        let exe = (path as NSString).lastPathComponent
        if let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return ("\(exe) \((script as NSString).lastPathComponent)".truncated(36), .other)
        }
        return (exe, .other)
    }

    static func health(_ m: SystemMemory) -> Health {
        guard m.total > 0 else { return .healthy }
        let swapRatio = Double(m.swapUsed) / Double(m.total)
        if m.pressureLevel >= 4 || m.freePercent < 15 || (swapRatio > 0.5 && m.freePercent < 50) { return .critical }
        if m.pressureLevel >= 2 || m.freePercent < 30 || (swapRatio > 0.25 && m.freePercent < 60) { return .tight }
        return .healthy
    }

    // MARK: Snapshot

    static func analyze(scanner: ProcessScanner) -> Snapshot {
        let memory = SystemMemory.read()
        let procs = scanner.scan()
        let me = getuid()
        let now = Date()

        var children: [pid_t: [pid_t]] = [:]
        for p in procs.values where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }

        func subtree(_ root: pid_t) -> [pid_t] {
            var out: [pid_t] = []
            var stack = [root]
            while let x = stack.popLast() {
                out.append(x)
                stack.append(contentsOf: children[x] ?? [])
            }
            return out
        }
        func bytes(_ pids: [pid_t]) -> UInt64 { pids.reduce(0) { $0 + (procs[$1]?.footprint ?? 0) } }
        func ancestors(_ pid: pid_t) -> [Proc] {
            var out: [Proc] = []
            var cur = procs[pid]?.ppid
            while let c = cur, c > 1, out.count < 40, let p = procs[c] {
                out.append(p)
                cur = p.ppid
            }
            return out
        }

        let engines = procs.values.filter { $0.uid == me && isEngine($0) }
        let engineIDs = Set(engines.map(\.pid))
        func host(of pid: pid_t) -> (name: String, path: String)? {
            for a in ancestors(pid) where !engineIDs.contains(a.pid) {
                if let b = bundle(of: a.path) { return b }
            }
            return nil
        }

        // Dev runs: a dev process with no dev ancestor before the session/app that launched it.
        var runs: [DevRun] = []
        for p in procs.values where p.uid == me && !engineIDs.contains(p.pid) && isDev(p) {
            var isRoot = true
            var launcher = "Background"
            var viaClaude = false
            for a in ancestors(p.pid) {
                if engineIDs.contains(a.pid) {
                    launcher = host(of: a.pid)?.name ?? "Claude Code"
                    viaClaude = true
                    break
                }
                if isDev(a) { isRoot = false; break }
                if let b = bundle(of: a.path) { launcher = b.name; break }
            }
            guard isRoot else { continue }
            let pids = subtree(p.pid)
            let total = bytes(pids)
            guard total >= 100 * MB else { continue }
            let orphan = p.ppid == 1
            let (label, kind) = devLabel(args: scanner.arguments(p), path: p.path)
            runs.append(DevRun(
                rootPID: p.pid, label: label, kind: kind,
                folder: Fmt.folder(scanner.cwd(p.pid), components: 2),
                launcher: orphan ? "No parent" : launcher, viaClaude: viaClaude, isOrphan: orphan,
                footprint: total,
                pids: pids.compactMap { procs[$0].map { PidRef(pid: $0.pid, start: $0.start) } },
                uptime: now.timeIntervalSince(p.start)
            ))
        }
        runs.sort { $0.footprint > $1.footprint }

        // A session is an engine the app started; engines spawned inside a session are part of it.
        let sessionEngines = engines.filter { e in !ancestors(e.pid).contains { engineIDs.contains($0.pid) } }
        var claimed = Set<pid_t>()
        var sessions: [CodeSession] = []
        for e in sessionEngines {
            let sub = subtree(e.pid)
            claimed.formUnion(sub)
            let h = host(of: e.pid)
            let busiest = runs.first { r in ancestors(r.rootPID).contains { $0.pid == e.pid } }
            sessions.append(CodeSession(
                pid: e.pid, host: h?.name ?? "Terminal", hostBundle: h?.path,
                folder: Fmt.folder(scanner.cwd(e.pid)),
                uptime: now.timeIntervalSince(e.start),
                own: e.footprint, children: bytes(sub) - e.footprint,
                activity: busiest.map { "running \($0.label) · \(Fmt.bytes($0.footprint))" }
            ))
        }
        sessions.sort { $0.own + $0.children > $1.own + $1.children }
        for r in runs { claimed.formUnion(r.pids.map(\.pid)) }

        var groups: [String: AppGroup] = [:]
        for p in procs.values where p.uid == me && p.footprint > 0 && !claimed.contains(p.pid) {
            let b = bundle(of: p.path)
            let key = b?.path ?? (p.path as NSString).lastPathComponent
            var g = groups[key] ?? AppGroup(id: key, name: b?.name ?? key, bundlePath: b?.path, footprint: 0, count: 0)
            g.footprint += p.footprint
            g.count += 1
            groups[key] = g
        }
        let sortedApps = groups.values.sorted { $0.footprint > $1.footprint }
        let rest = sortedApps.dropFirst(7)

        var tabs: [BrowserTab] = []
        for p in procs.values where p.uid == me && p.footprint >= 400 * MB {
            guard let b = bundle(of: p.path), browsers.contains(b.name) else { continue }
            let args = scanner.arguments(p)
            guard args.contains("--type=renderer") else { continue }
            tabs.append(BrowserTab(
                ref: PidRef(pid: p.pid, start: p.start), browser: b.name, bundlePath: b.path,
                isExtension: args.contains("--extension-process"), footprint: p.footprint,
                uptime: now.timeIntervalSince(p.start)
            ))
        }
        tabs.sort { $0.footprint > $1.footprint }

        var snap = Snapshot()
        snap.memory = memory
        snap.demand = procs.values.reduce(0) { $0 + $1.footprint }
        snap.apps = Array(sortedApps.prefix(7))
        snap.otherBytes = rest.reduce(0) { $0 + $1.footprint }
        snap.otherCount = rest.reduce(0) { $0 + $1.count }
        snap.sessions = sessions
        snap.devRuns = runs
        snap.tabs = tabs
        return finish(snap)
    }

    /// Fills in health, the summary line and insights from the raw sections.
    static func finish(_ input: Snapshot) -> Snapshot {
        var s = input
        let m = s.memory
        s.health = health(m)
        let ram = Fmt.ram(m.total)
        switch s.health {
        case .critical, .tight:
            s.summary = s.demand > m.total
                ? "Apps want \(Fmt.bytes(s.demand)) on a \(ram) Mac, so macOS has pushed \(Fmt.bytes(m.swapUsed)) to disk as swap. That's what slows things down."
                : "\(Fmt.bytes(m.used)) of \(ram) in use, plus \(Fmt.bytes(m.swapUsed)) in swap."
        case .healthy:
            s.summary = "\(Fmt.bytes(m.used)) of \(ram) in use, with room to spare."
        }
        s.insights = insights(s)
        s.takenAt = Date()
        return s
    }

    static func insights(_ s: Snapshot) -> [Insight] {
        var out: [Insight] = []

        // Heavy test/build runs — the cause of most of the trouble in practice.
        let heavy = s.devRuns.filter { $0.footprint >= 300 * MB && $0.kind != .server && !$0.isOrphan }
        let heavyTotal = heavy.reduce(0) { $0 + $1.footprint }
        if heavyTotal >= 3 * GB / 2 || heavy.count >= 3 {
            var counts: [(String, Int)] = []
            for run in heavy {
                let tool = run.label.split(separator: " ").first.map(String.init) ?? run.label
                if let i = counts.firstIndex(where: { $0.0 == tool }) { counts[i].1 += 1 } else { counts.append((tool, 1)) }
            }
            let what = counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
            let folders = Set(heavy.map(\.folder))
            var detail = "\(what) in " + (folders.count == 1 ? folders.first! : "\(folders.count) folders at once")
            let viaClaude = heavy.contains(where: \.viaClaude)
            detail += viaClaude ? ", started by a Claude Code session." : "."
            if folders.count > 1 { detail += " Running one folder at a time would need a fraction of this." }
            var actions: [InsightAction] = []
            if viaClaude { actions.append(InsightAction(title: "Copy note for the agent", kind: .copyAgentNote)) }
            actions.append(InsightAction(title: heavy.count == 1 ? "End it…" : "End all \(heavy.count)…", kind: .endRuns(heavy), destructive: true))
            out.append(Insight(
                id: "dev", severity: heavyTotal >= 3 * GB ? .critical : .warning,
                title: "Test and build runs are using \(Fmt.bytes(heavyTotal))",
                detail: detail, bytes: heavyTotal, actions: actions
            ))
        }

        for run in s.devRuns where run.isOrphan && run.kind != .server && run.footprint >= 200 * MB {
            out.append(Insight(
                id: "orphan-\(run.rootPID)", severity: .warning,
                title: "\(run.label) was left running",
                detail: "It's using \(Fmt.bytes(run.footprint)) in \(run.folder), and whatever started it has already exited.",
                bytes: run.footprint,
                actions: [InsightAction(title: "End it…", kind: .endRuns([run]), destructive: true)]
            ))
        }

        for tab in s.tabs where tab.footprint >= GB {
            let short = tab.browser.replacingOccurrences(of: "Google ", with: "")
            let finder = tab.browser.hasPrefix("Google Chrome")
                ? "In Chrome, Window → Task Manager shows which one it is."
                : "The browser's Task Manager shows which one it is."
            out.append(Insight(
                id: "tab-\(tab.id)", severity: .warning,
                title: "A \(short) \(tab.isExtension ? "extension" : "tab or web app") is using \(Fmt.bytes(tab.footprint))",
                detail: "Open for \(Fmt.duration(tab.uptime)). \(finder)",
                bytes: tab.footprint,
                actions: [InsightAction(title: "End it…", kind: .endTab(tab), destructive: true)]
            ))
        }

        let claudeApps = s.apps.filter { $0.name == "Claude" || $0.name.hasPrefix("Claude ") }
        if claudeApps.count >= 2 {
            let total = claudeApps.reduce(0) { $0 + $1.footprint }
            out.append(Insight(
                id: "claude-apps", severity: .info,
                title: "\(claudeApps.count) Claude apps are open, using \(Fmt.bytes(total))",
                detail: "Quit the ones you aren't using. Hover over an app below to quit it.",
                bytes: total
            ))
        }

        if s.sessions.count >= 4 {
            let total = s.sessions.reduce(0) { $0 + $1.own }
            out.append(Insight(
                id: "sessions", severity: .info,
                title: "\(s.sessions.count) Claude Code sessions are open",
                detail: "Each one keeps its own process (\(Fmt.bytes(total)) together). Close or archive finished ones from the app's sidebar.",
                bytes: total
            ))
        }

        for run in s.devRuns where run.uptime > 12 * 3600 && run.footprint >= 100 * MB && !run.isOrphan {
            out.append(Insight(
                id: "long-\(run.rootPID)", severity: .info,
                title: "\(run.label) has been running for \(Fmt.duration(run.uptime))",
                detail: "In \(run.folder), using \(Fmt.bytes(run.footprint)). Stop it if you aren't using it.",
                bytes: run.footprint,
                actions: [InsightAction(title: "End it…", kind: .endRuns([run]), destructive: true)]
            ))
        }

        if s.health == .healthy && s.memory.swapUsed >= 3 * GB / 2 {
            out.append(Insight(
                id: "swap", severity: .info,
                title: "\(Fmt.bytes(s.memory.swapUsed)) is still in swap",
                detail: "There's room in memory now, so macOS moves it back on its own as you use your apps. Nothing to do.",
                bytes: 0
            ))
        }

        return Array(out.sorted { ($0.severity.rawValue, $0.bytes) > ($1.severity.rawValue, $1.bytes) }.prefix(5))
    }

    /// A note to paste into a coding agent that's running too many heavy commands at once, with live numbers.
    static func agentNote(_ s: Snapshot) -> String {
        let runs = s.devRuns.filter(\.viaClaude)
        let total = runs.reduce(0) { $0 + $1.footprint }
        let folders = Set(runs.map(\.folder)).sorted().joined(separator: ", ")
        let swapLimit = max(2, Int((Double(s.memory.total) / Double(GB) / 2).rounded()))
        return """
        Heads up: this Mac has \(Fmt.ram(s.memory.total)) of RAM and it's under memory pressure (\(Fmt.bytes(s.memory.swapUsed)) of swap used). \
        Your test and build runs are using about \(Fmt.bytes(total)) right now\(folders.isEmpty ? "" : " (\(folders))"). \
        Please follow these rules for the rest of this session:

        1. One worktree at a time. Never run tests or type checks in more than one worktree at once. If you have parallel subagents, they can write code in parallel, but verification runs must take turns.
        2. Don't run jest and tsc at the same time. Finish one before starting the other.
        3. Cap jest: always pass --maxWorkers=2 --workerIdleMemoryLimit=1G. Run only the test files related to what you changed. Run the full suite only once, at the very end.
        4. Run tsc --noEmit once per worktree, after the edits are done, not after every change.
        5. Check memory before any heavy run: `sysctl vm.swapusage`. If more than \(swapLimit) GB of swap is used, wait for other runs to finish and run things one by one.
        6. Clean up when you're done. Leave no watch-mode or orphaned jest/tsc processes behind. Check with `pgrep -fl "jest|tsc"` and kill anything you started that's still running.

        Reply with a one-line confirmation, then carry on with these limits.
        """
    }
}
