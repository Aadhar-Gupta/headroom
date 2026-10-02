import AppKit
import SwiftUI

enum StatusIcon {
    /// Monochrome template when healthy (so it matches the menu bar), tinted orange/red otherwise.
    static func image(for health: Health) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let config: NSImage.SymbolConfiguration
        switch health {
        case .healthy: config = base
        case .tight: config = base.applying(.init(paletteColors: [.systemOrange]))
        case .critical: config = base.applying(.init(paletteColors: [.systemRed]))
        }
        let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: health.headline)?
            .withSymbolConfiguration(config)
        image?.isTemplate = health == .healthy
        return image
    }
}

enum Renderer {
    /// Draws the panel to a PNG without opening any window (`--render path [--demo] [--dark]`).
    @MainActor
    static func renderPanel(_ snap: Snapshot, to path: String, dark: Bool) {
        let model = Model(snapshot: snap)
        let view = PanelView(rendering: true)
            .environmentObject(model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.17) : Color(white: 0.97))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { print("render failed"); return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

enum AppIconMaker {
    /// Writes a .iconset folder for `iconutil` (`--make-iconset path`).
    @MainActor
    static func makeIconset(at dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
            ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in specs {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }

    private static func draw(in rect: NSRect) {
        // macOS icon grid: 824pt body on a 1024pt canvas.
        let body = rect.insetBy(dx: rect.width * 0.0977, dy: rect.width * 0.0977)
        let w = body.width
        let shape = NSBezierPath(roundedRect: body, xRadius: w * 0.225, yRadius: w * 0.225)
        NSGradient(colors: [
            NSColor(srgbRed: 0.13, green: 0.17, blue: 0.27, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 1),
        ])?.draw(in: shape, angle: -90)

        // Gauge: the dial shows how much headroom is left.
        let center = NSPoint(x: body.midX, y: body.midY - w * 0.04)
        let radius = w * 0.32
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 210, endAngle: -30, clockwise: true)
        track.lineWidth = w * 0.075
        track.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.14).setStroke()
        track.stroke()

        let fill = NSBezierPath()
        fill.appendArc(withCenter: center, radius: radius, startAngle: 210, endAngle: 75, clockwise: true)
        fill.lineWidth = w * 0.075
        fill.lineCapStyle = .round
        NSColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 1).setStroke()
        fill.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: w * 0.24, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let chip = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = chip.size
            chip.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                 width: size.width, height: size.height))
        }
    }
}
