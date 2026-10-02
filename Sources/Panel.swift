import SwiftUI
import AppKit

extension Health {
    var color: Color {
        switch self {
        case .healthy: .green
        case .tight: .orange
        case .critical: .red
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

extension DevKind {
    var symbol: String {
        switch self {
        case .test: "testtube.2"
        case .typecheck: "chevron.left.forwardslash.chevron.right"
        case .build: "hammer.fill"
        case .server: "server.rack"
        case .other: "terminal.fill"
        }
    }

    var color: Color {
        switch self {
        case .test: .purple
        case .typecheck: .blue
        case .build: .orange
        case .server: .teal
        case .other: .gray
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var model: Model
    /// Offscreen rendering (`--render`) can't draw scroll views, so lay everything out flat.
    var rendering = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 0) {
            HeaderView(s: s)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            Divider()
            if rendering {
                SectionsView(s: s)
            } else {
                ScrollView(.vertical) {
                    SectionsView(s: s)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: min(max(contentHeight, 80), 540))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
            Divider()
            FooterView()
        }
        .frame(width: 384)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Header

private struct HeaderView: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(s.health.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: s.health.color.opacity(0.7), radius: 3)
                Text(s.health.headline)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(s.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            UsageBar(fraction: s.usedFraction, color: s.health.color)
                .padding(.top, 2)

            HStack(spacing: 0) {
                StatTile(label: "Used", value: Fmt.bytes(s.memory.used))
                StatTile(label: "Swap", value: Fmt.bytes(s.memory.swapUsed),
                         tint: s.health == .healthy ? nil : s.health.color)
                StatTile(label: "Free", value: "\(s.memory.freePercent)%")
                // Demand only counts your own processes, so it's only meaningful once it outgrows what's in use.
                if s.demand > s.memory.used {
                    StatTile(label: "Apps want", value: Fmt.bytes(s.demand),
                             tint: s.demand > s.memory.total ? s.health.color : nil)
                        .help("Everything your apps are holding, including what macOS has compressed or moved to swap.")
                } else {
                    StatTile(label: "Pressure", value: s.memory.pressureLevel >= 4 ? "Critical" : s.memory.pressureLevel >= 2 ? "Warning" : "Normal")
                }
            }
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(6, g.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sections

private struct SectionsView: View {
    @EnvironmentObject var model: Model
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                if s.insights.isEmpty {
                    AllClear()
                } else {
                    ForEach(s.insights) { InsightCard(insight: $0) }
                }
            }

            PanelSection("Apps") {
                let top = s.apps.first?.footprint ?? 1
                ForEach(s.apps) { app in
                    UsageRow(
                        icon: app.bundlePath.map(RowIcon.app) ?? .symbol("gearshape.fill", .gray),
                        title: app.name,
                        subtitle: app.count > 1 ? "\(app.count) processes" : nil,
                        bytes: app.footprint, maxBytes: top,
                        action: app.canQuit ? RowAction(title: "Quit") { model.quit(app) } : nil
                    )
                }
                if s.otherBytes > 0 {
                    UsageRow(icon: .symbol("ellipsis", .gray), title: "Everything else",
                             subtitle: "\(s.otherCount) processes", bytes: s.otherBytes, maxBytes: top)
                }
            }

            if !s.sessions.isEmpty {
                PanelSection("Claude Code sessions", note: "Close finished ones in the sidebar") {
                    let top = s.sessions.map { $0.own + $0.children }.max() ?? 1
                    ForEach(s.sessions) { ses in
                        UsageRow(
                            icon: ses.hostBundle.map(RowIcon.app) ?? .symbol("terminal.fill", .gray),
                            title: ses.folder,
                            subtitle: "\(ses.host) · open \(Fmt.duration(ses.uptime))",
                            detail: ses.activity,
                            bytes: ses.own + ses.children, maxBytes: top
                        )
                    }
                }
            }

            if !s.devRuns.isEmpty {
                PanelSection("Dev tools") {
                    let top = s.devRuns.first?.footprint ?? 1
                    ForEach(s.devRuns) { run in
                        UsageRow(
                            icon: .symbol(run.kind.symbol, run.kind.color),
                            title: run.label,
                            subtitle: "\(run.folder) · \(run.launcher) · \(Fmt.duration(run.uptime))",
                            bytes: run.footprint, maxBytes: top,
                            action: RowAction(title: "End") { model.end(runs: [run]) }
                        )
                    }
                }
            }

            if !s.tabs.isEmpty {
                PanelSection("Heavy browser tabs", note: "Task Manager in the browser names them") {
                    let top = s.tabs.first?.footprint ?? 1
                    ForEach(s.tabs) { tab in
                        UsageRow(
                            icon: .app(tab.bundlePath),
                            title: tab.isExtension ? "Extension" : "Tab or web app",
                            subtitle: "PID \(tab.ref.pid) · open \(Fmt.duration(tab.uptime))",
                            bytes: tab.footprint, maxBytes: top,
                            action: RowAction(title: "End") { model.end(tab: tab) }
                        )
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 14, trailing: 10))
    }
}

private struct AllClear: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Nothing needs your attention")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.08)))
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
            content
        }
    }
}

// MARK: - Insight card

private struct InsightCard: View {
    @EnvironmentObject var model: Model
    let insight: Insight

    var body: some View {
        let c = insight.severity.color
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insight.severity.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !insight.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(insight.actions) { a in
                            Button(a.title) { model.perform(a.kind) }
                                .buttonStyle(PillButtonStyle(tint: a.destructive ? .red : .accentColor, prominent: !a.destructive))
                        }
                    }
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(c.opacity(0.22), lineWidth: 0.5))
    }
}

// MARK: - Rows

enum RowIcon {
    case app(String)
    case symbol(String, Color)
}

struct RowAction {
    let title: String
    let run: () -> Void
}

private struct RowIconView: View {
    @EnvironmentObject var model: Model
    let icon: RowIcon

    var body: some View {
        switch icon {
        case .app(let path):
            Image(nsImage: model.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.16)))
        }
    }
}

private struct UsageRow: View {
    let icon: RowIcon
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    let bytes: UInt64
    let maxBytes: UInt64
    var action: RowAction? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RowIconView(icon: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                MiniBar(fraction: maxBytes > 0 ? Double(bytes) / Double(maxBytes) : 0)
                    .opacity(hovering && action != nil ? 0 : 1)
                if hovering, let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(PillButtonStyle(tint: .red))
                }
            }
            .frame(width: 50, alignment: .trailing)

            Text(Fmt.bytes(bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let action { Button(action.title, action: action.run) }
        }
    }
}

private struct MiniBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: max(3, 44 * min(1, fraction)))
        }
        .frame(width: 44, height: 4)
    }
}

// MARK: - Footer

private struct FooterView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 2) {
            Button { model.openActivityMonitor() } label: {
                Label("Activity Monitor", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(FooterButtonStyle())
            Spacer()
            if let flash = model.flash {
                Text(flash)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(FooterButtonStyle())
                .help("Refresh now")
            Button { model.showSettingsMenu?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(FooterButtonStyle())
                .help("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Button styles

struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(prominent ? Color.white : tint)
            .background(Capsule().fill(prominent ? tint : tint.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButton(configuration: configuration)
    }

    private struct FooterButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
