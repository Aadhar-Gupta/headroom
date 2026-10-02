import AppKit

let arguments = CommandLine.arguments
let useDemo = arguments.contains("--demo")

MainActor.assumeIsolated {
    if arguments.contains("--dump") {
        print(Report.text(useDemo ? Report.demo : Analyzer.analyze(scanner: ProcessScanner())))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--render"), i + 1 < arguments.count {
        _ = NSApplication.shared
        let snap = useDemo ? Report.demo : Analyzer.analyze(scanner: ProcessScanner())
        Renderer.renderPanel(snap, to: arguments[i + 1], dark: arguments.contains("--dark"))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--make-iconset"), i + 1 < arguments.count {
        AppIconMaker.makeIconset(at: arguments[i + 1])
        exit(0)
    }

    // One copy at a time.
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
