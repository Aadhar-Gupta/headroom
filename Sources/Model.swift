import AppKit
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published private(set) var snapshot: Snapshot
    @Published var flash: String?

    var onUpdate: ((Snapshot) -> Void)?
    var showSettingsMenu: (() -> Void)?

    private let scanner = ProcessScanner()
    private let queue = DispatchQueue(label: "headroom.scan", qos: .utility)
    private var scanning = false
    private var iconCache: [String: NSImage] = [:]

    init(snapshot: Snapshot = Snapshot()) {
        self.snapshot = snapshot
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        queue.async {
            let snap = Analyzer.analyze(scanner: scanner)
            DispatchQueue.main.async { self.apply(snap) }
        }
    }

    private func apply(_ snap: Snapshot) {
        var s = snap
        let running = NSWorkspace.shared.runningApplications
        for i in s.apps.indices {
            guard let path = s.apps[i].bundlePath else { continue }
            s.apps[i].canQuit = running.contains {
                $0.bundleURL?.path == path && $0.activationPolicy == .regular && $0.processIdentifier != getpid()
            }
        }
        scanning = false
        snapshot = s
        onUpdate?(s)
    }

    func icon(for bundlePath: String) -> NSImage {
        if let cached = iconCache[bundlePath] { return cached }
        let img = NSWorkspace.shared.icon(forFile: bundlePath)
        iconCache[bundlePath] = img
        return img
    }

    // MARK: Actions

    func perform(_ kind: ActionKind) {
        switch kind {
        case .copyAgentNote: copyAgentNote()
        case .endRuns(let runs): end(runs: runs)
        case .endTab(let tab): end(tab: tab)
        }
    }

    func copyAgentNote() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Analyzer.agentNote(snapshot), forType: .string)
        show("Copied. Paste it into the Claude session.")
    }

    func end(runs: [DevRun]) {
        guard !runs.isEmpty else { return }
        let total = runs.reduce(0) { $0 + $1.footprint }
        let title = runs.count == 1 ? "End \(runs[0].label)?" : "End \(runs.count) test and build runs?"
        var message = runs.count == 1
            ? "This stops \(runs[0].pids.count) process\(runs[0].pids.count == 1 ? "" : "es") in \(runs[0].folder) and frees about \(Fmt.bytes(total))."
            : runs.map { "• \($0.label) in \($0.folder) (\(Fmt.bytes($0.footprint)))" }.joined(separator: "\n") + "\n\nFrees about \(Fmt.bytes(total))."
        if runs.contains(where: \.viaClaude) {
            message += "\n\nA Claude Code session started this. It will see the command fail and can run it again later."
        }
        guard confirm(title, message, button: "End") else { return }
        var ended = 0
        for run in runs {
            for ref in run.pids.reversed() where ProcessScanner.terminate(ref) { ended += 1 }
        }
        show(ended > 0 ? "Ended \(ended) process\(ended == 1 ? "" : "es")." : "Already finished.")
        refreshSoon()
    }

    func end(tab: BrowserTab) {
        let message = "Frees about \(Fmt.bytes(tab.footprint)). The \(tab.isExtension ? "extension restarts" : "tab shows “Aw, Snap!” and comes back when you reload it"). Anything typed and unsent in it is lost."
        guard confirm("End this \(tab.browser) \(tab.isExtension ? "extension" : "tab")?", message, button: "End") else { return }
        show(ProcessScanner.terminate(tab.ref) ? "Ended it." : "Already closed.")
        refreshSoon()
    }

    func quit(_ app: AppGroup) {
        guard let path = app.bundlePath,
              let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path })
        else { return }
        guard confirm("Quit \(app.name)?", "Frees about \(Fmt.bytes(app.footprint)). The app asks about anything unsaved before it closes.", button: "Quit") else { return }
        running.terminate()
        show("Asked \(app.name) to quit.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    private func show(_ message: String) {
        withAnimation { flash = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.flash == message { withAnimation { self.flash = nil } }
        }
    }

    private func confirm(_ title: String, _ message: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
