import AppKit
import SwiftUI
import Combine

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store!
    private var panel: NotchPanel!
    private var status: NSStatusItem!
    private let state = PanelState()
    private var observers = Set<AnyCancellable>()
    private let capture = ProcessInfo.processInfo.environment["NOTCH_CAPTURE_PATH"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac Notch Session Companion")
        let root = env["NOTCH_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? fallback
        let sessions = env["NOTCH_SESSION_DIR"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Sessions")
        let firstLaunch = !FileManager.default.fileExists(atPath: root.appendingPathComponent("selection.json").path)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let main = NSMenu()
        for submenu in [NSMenu(title: "watchnotch"), edit] {
            let item = NSMenuItem()
            main.addItem(item)
            item.submenu = submenu
        }
        NSApp.mainMenu = main
        store = Store(root: root, directory: sessions)
        for pin in store.saved.watches ?? [] where store.saved.pins.contains(pin) {
            if pin.provider == "Codex" { _ = store.watchCodex(pin.sessionID) }
        }
        panel = NotchPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Notch sessions")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show or hide sessions",action: #selector(toggle),keyEquivalent: "")
        show.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit watchnotch",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        status.menu = menu
        NotificationCenter.default.addObserver(self,selector: #selector(layout),name: NSApplication.didChangeScreenParametersNotification,object: nil)
        state.expanded = firstLaunch || capture != nil || env["NOTCH_EXPANDED"] == "1"
        if capture != nil { store.tick(now: Date().addingTimeInterval(10)) }
        panel.contentView = NSHostingView(rootView: PanelView(store: store, panel: state, toggle: { [weak self] in self?.toggle() }))
        // Update window geometry independently so pinning or incoming events preserve field focus.
        Publishers.MergeMany(state.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                             store.$saved.map { $0.pins.count }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                             store.$notice.map { $0 != nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] in self?.layout() }.store(in: &observers)
        layout()
        if let capture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let view = self.panel.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds,to: bitmap)
                guard let png = bitmap.representation(using: .png,properties: [:]) else { exit(1) }
                do { try png.write(to: URL(fileURLWithPath: capture)); NSApp.terminate(nil) } catch { exit(1) }
            }
        }
    }

    @objc private func toggle() {
        state.expanded.toggle()
        if !state.expanded { state.managing = false }
        layout()
        if state.expanded { panel.makeKeyAndOrderFront(nil) }
    }

    @objc private func layout() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let hasNotch = screen.safeAreaInsets.top > 0 && left != nil && right != nil
        let widthOfNotch = hasNotch ? right!.minX - left!.maxX : 0
        let center = hasNotch ? (left!.maxX + right!.minX)/2 : screen.frame.midX
        let expanded = state.expanded
        let band = expanded && !state.managing
        let expandedWidth = band ? screen.frame.width : min(466,screen.visibleFrame.width)
        if state.displayWidth != screen.frame.width { state.displayWidth = screen.frame.width }
        let expandedHeight = state.managing ? CGFloat(470) : (store.pinned.isEmpty ? 96 : state.rowHeight + 40) + (store.notice == nil ? 0 : 40)
        let width: CGFloat = expanded ? expandedWidth : max(120,widthOfNotch + 104)
        let height: CGFloat = expanded ? min(expandedHeight,screen.visibleFrame.height - 12) : max(24,screen.safeAreaInsets.top)
        let top = hasNotch && !expanded ? screen.frame.maxY : min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        let rect = NSRect(x: band ? screen.frame.minX : center - width/2,y: top - height,width: width,height: height)
        panel.setFrame(rect,display: true)
        panel.hasShadow = false
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) { store?.stopMonitors() }
}

umask(0o077)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
