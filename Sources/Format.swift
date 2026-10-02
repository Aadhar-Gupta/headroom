import Foundation

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    /// Whole-GB label for installed RAM, e.g. "16 GB".
    static func ram(_ b: UInt64) -> String {
        "\(Int((Double(b) / 1_073_741_824).rounded())) GB"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Short project label: worktrees as "repo › leaf" (e.g. "storefront › checkout"), Claude scratch sessions as "No folder",
    /// anything else as its last `components` path components.
    static func folder(_ path: String?, components: Int = 1) -> String {
        guard let path, !path.isEmpty, path != "/" else { return "Unknown folder" }
        if path.contains("/scratch-workspaces/") { return "No folder" }
        if let r = path.range(of: "/.worktrees/") {
            let repo = (String(path[..<r.lowerBound]) as NSString).lastPathComponent
            return "\(repo) › \((String(path[r.upperBound...]) as NSString).lastPathComponent)"
        }
        if path == NSHomeDirectory() { return "Home" }
        let parts = (path as NSString).pathComponents.filter { $0 != "/" }
        return parts.suffix(components).joined(separator: "/")
    }
}

extension String {
    func truncated(_ n: Int) -> String {
        count > n ? String(prefix(n - 1)) + "…" : self
    }
}
