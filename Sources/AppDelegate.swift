import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let model = Model()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var lastHealth = Health.healthy
    private var lastNotified = Date.distantPast
    private let defaults = UserDefaults.standard

    private enum Key {
        static let notify = "notifyWhenTight"
        static let showPercent = "showPercentInMenuBar"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Key.notify: true, Key.showPercent: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        model.onUpdate = { [weak self] in self?.didUpdate($0) }
        model.showSettingsMenu = { [weak self] in self?.showMenu(from: nil) }
        updateButton(model.snapshot)
        model.refresh()
        schedule(every: 10)

        UNUserNotificationCenter.current().delegate = self
        if defaults.bool(forKey: Key.notify) { requestNotificationPermission() }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        schedule(every: 3)
    }

    func popoverDidClose(_ notification: Notification) {
        schedule(every: 10)
    }

    private func schedule(every seconds: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        model.refresh()
    }

    private func didUpdate(_ s: Snapshot) {
        updateButton(s)
        if s.health == .critical, lastHealth != .critical, defaults.bool(forKey: Key.notify),
           Date().timeIntervalSince(lastNotified) > 30 * 60 {
            postNotification(s)
            lastNotified = Date()
        }
        lastHealth = s.health
    }

    private func updateButton(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: s.health)
        if defaults.bool(forKey: Key.showPercent), s.memory.total > 0 {
            button.title = " \(Int((s.usedFraction * 100).rounded()))%"
        } else {
            button.title = ""
        }
        button.toolTip = s.memory.total > 0
            ? "\(s.health.headline): \(Fmt.bytes(s.memory.used)) of \(Fmt.ram(s.memory.total)) used, \(Fmt.bytes(s.memory.swapUsed)) in swap"
            : "Headroom"
    }

    // MARK: Settings menu

    private func showMenu(from button: NSStatusBarButton?) {
        let menu = NSMenu()
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Notify When Memory Gets Tight", #selector(toggleNotify), on: defaults.bool(forKey: Key.notify)))
        menu.addItem(item("Show Usage in Menu Bar", #selector(togglePercent), on: defaults.bool(forKey: Key.showPercent)))
        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(tick)))
        menu.addItem(item("Open Activity Monitor", #selector(openActivityMonitor)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if let button {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.runModal()
        }
    }

    @objc private func toggleNotify() {
        let on = !defaults.bool(forKey: Key.notify)
        defaults.set(on, forKey: Key.notify)
        if on { requestNotificationPermission() }
    }

    @objc private func togglePercent() {
        defaults.set(!defaults.bool(forKey: Key.showPercent), forKey: Key.showPercent)
        updateButton(model.snapshot)
    }

    @objc private func openActivityMonitor() {
        model.openActivityMonitor()
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(_ s: Snapshot) {
        let content = UNMutableNotificationContent()
        content.title = s.health.headline
        content.body = s.insights.first.map { "\($0.title). Click to see what's using it." }
            ?? "Click to see what's using it."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "headroom.tight", content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { self.showPopover() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
