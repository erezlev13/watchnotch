import AppKit
import ApplicationServices

struct SessionJump {
    let desktop: URL?
    let web: URL?
    private let deviceAvailable: Bool
    private let chatTitle: String?

    init?(card: Card, pairedWebLink: URL? = nil) {
        guard card.origin == .adapter else { return nil }
        let snapshot = card.value
        chatTitle = snapshot.provider == "ChatGPT" ? snapshot.nativeChatTitle : nil
        deviceAvailable = snapshot.state != .unavailable
        switch snapshot.provider {
        case "ChatGPT":
            guard let url = snapshot.sessionURL,
                  let (id, canonical) = Format.chatLink(url.absoluteString),
                  id == snapshot.sessionID.lowercased() else { return nil }
            desktop = nil
            web = canonical
        case "Codex":
            guard let uuid = UUID(uuidString: snapshot.sessionID) else { return nil }
            desktop = URL(string: "codex://threads/" + uuid.uuidString.lowercased())
            web = [pairedWebLink, snapshot.sessionURL].compactMap { $0 }.compactMap { Self.webLink($0.absoluteString) }.first
        default: return nil
        }
    }

    static func webLink(_ input: String) -> URL? {
        if let (_, url) = Format.chatLink(input) { return url }
        guard let parts = URLComponents(string: input), parts.scheme == "https", parts.host?.lowercased() == "chatgpt.com",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let pattern = #"^/codex/(?:tasks/)?task_[A-Za-z0-9_-]+/?$"#
        guard parts.path.range(of: pattern,options: .regularExpression) != nil else { return nil }
        return URL(string: "https://chatgpt.com" + parts.path)
    }

    enum Step: Equatable {
        case matchingWindow(URL)
        case desktop(URL)
        case chatWindow(URL)
        case universalLink(URL)
        case browser(URL)
    }

    func steps(providerRunning: Bool) -> [Step] {
        var result: [Step] = []
        if desktop == nil, let web, providerRunning {
            return [.chatWindow(web), .universalLink(web)]
        }
        if let web, providerRunning { result.append(.matchingWindow(web)) }
        if let desktop, (providerRunning && deviceAvailable) || web == nil { result.append(.desktop(desktop)) }
        if let web {
            result.append(.browser(web))
        }
        return result
    }

    @MainActor
    func open(browserOnly: Bool = false) async -> Bool {
        let ids = ["com.openai.codex","com.openai.chat"]
        let apps = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        let steps = browserOnly ? web.map { [Step.browser($0)] } ?? [] : steps(providerRunning: !apps.isEmpty)
        let workspace = NSWorkspace.shared
        for step in steps {
            switch step {
            case .chatWindow(let url):
                let nativeOnly = apps.filter { $0.bundleIdentifier == "com.openai.chat" }
                if let title = chatTitle, Self.activateFrontChat(title, in: nativeOnly) { return true }
                if Self.raiseMatchingWindow(url, in: nativeOnly) { return true }
                if AXIsProcessTrusted() {
                    for app in apps where Self.selectChat(url, title: chatTitle, in: app) { return true }
                    // The desktop app could be open on another chat with the target absent.
                    // Leave the explicit browser action available in the tile.
                } else {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
            case .matchingWindow(let url):
                if Self.raiseMatchingWindow(url,in: apps) { return true }
            case .desktop(let url):
                let appURL = apps.first { $0.bundleIdentifier == "com.openai.codex" }?.bundleURL
                    ?? workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
                if let appURL, await Self.deliver(url,to: appURL) { return true }
            case .universalLink(let url):
                // The unified desktop app accepts HTTPS into its browser panel.
                // Its private-chat route must instead be selected in the native shell.
                guard apps.contains(where: { $0.bundleIdentifier == "com.openai.chat" }) else { continue }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.requiresUniversalLinks = true
                if let opened = try? await workspace.open(url, configuration: configuration),
                   opened.bundleIdentifier == "com.openai.chat" { return true }
            case .browser(let url):
                // Resolve the user's ordinary HTTPS browser separately from app-associated session links.
                let sample = URL(string: "https://example.com")!
                if let browser = workspace.urlForApplication(toOpen: sample), await Self.deliver(url,to: browser) { return true }
            }
        }
        return false
    }

    @MainActor static func openResult(_ url: URL) async -> Bool {
        if let viewer = Format.resultViewer(url) { return await deliver(url, to: viewer) }
        guard Format.webResult(url), let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return await deliver(url, to: browser)
    }

    @MainActor private static func deliver(_ url: URL,to app: URL) async -> Bool {
        do {
            _ = try await NSWorkspace.shared.open([url],withApplicationAt: app,configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch { return false }
    }

    // macOS may provide the current window title without Accessibility access. Only
    // activate when the app's front document matches a unique desktop catalog title.
    @MainActor private static func activateFrontChat(_ title: String, in apps: [NSRunningApplication]) -> Bool {
        guard !title.isEmpty, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for app in apps {
            let front = windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
            guard let name = front?[kCGWindowName as String] as? String, name == title else { continue }
            return app.activate(options: [])
        }
        return false
    }

    static func nativeChatURL(_ value: String) -> URL? {
        if let (_, canonical) = Format.chatLink(value) { return canonical }
        guard let parts = URLComponents(string: value), parts.scheme == "app", parts.host == "-",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path = parts.fragment.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? parts.path
        return Format.chatLink("https://chatgpt.com" + path)?.1
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }

    // Only select a conversation inside the app's own window, sidebar or tab list.
    // A link in a message is never a navigation target.
    @MainActor private static func selectChat(_ target: URL, title: String?, in app: NSRunningApplication) -> Bool {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let deadline = Date().addingTimeInterval(1.5)
        for window in windows {
            var queue: [(AXUIElement, Bool)] = [(window, false)]
            var index = 0
            while index < queue.count && index < 1500 && Date() < deadline {
                let (node, inNavigation) = queue[index]
                index += 1
                let role = attribute(node, kAXRoleAttribute) as? String ?? ""
                let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
                let unified = app.bundleIdentifier == "com.openai.codex"
                if role == "AXWebArea", let document = attribute(node, kAXURLAttribute) {
                    let address = (document as? URL)?.absoluteString ?? document as? String
                    if let address {
                        // Do not select either a document or its navigation in the embedded website.
                        if unified && URLComponents(string: address)?.scheme != "app" { continue }
                        if nativeChatURL(address) == target { return raise(window, in: app) }
                    }
                }
                let nav = inNavigation || subrole == "AXLandmarkNavigation" || subrole == "AXSidebar" ||
                    role == "AXTabGroup" || role == "AXOutline"
                if nav && ["AXLink", "AXButton", "AXRow", "AXRadioButton"].contains(role) {
                    let address = attribute(node, kAXURLAttribute)
                    let href = (address as? URL)?.absoluteString ?? address as? String
                    let matchesID = href.flatMap(nativeChatURL) == target
                    // Chromium can expose the row's aria-label as its AX description.
                    let matchesTitle = href == nil && title.map { expected in
                        [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                            attribute(node, $0) as? String == expected
                        }
                    } == true
                    if (matchesID || matchesTitle) && AXUIElementPerformAction(node, kAXPressAction as CFString) == .success {
                        return raise(window, in: app)
                    }
                }
                if ["AXTextArea","AXTextField","AXStaticText","AXLandmarkMain","AXDocumentArticle"].contains(role) ||
                    ["AXLandmarkMain","AXDocumentArticle"].contains(subrole) { continue }
                let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
                queue.append(contentsOf: children.prefix(max(0, 1500 - queue.count)).map { ($0, nav) })
            }
        }
        return false
    }

    @MainActor private static func raise(_ window: AXUIElement, in app: NSRunningApplication) -> Bool {
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        return app.isActive || app.activate(options: [])
    }

    @MainActor private static func raiseMatchingWindow(_ target: URL,in apps: [NSRunningApplication]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element,0.15)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,kAXWindowsAttribute as CFString,&raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            for window in windows {
                // Only window-level addresses identify the presented document; links inside chat content do not.
                for attribute in [kAXDocumentAttribute,kAXURLAttribute] {
                    var address: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window,attribute as CFString,&address) == .success else { continue }
                    let text = (address as? URL)?.absoluteString ?? address as? String
                    guard let text, webLink(text) == target else { continue }
                    _ = AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
                    guard AXUIElementPerformAction(window,kAXRaiseAction as CFString) == .success else { continue }
                    return app.activate(options: [])
                }
            }
        }
        return false
    }
}
