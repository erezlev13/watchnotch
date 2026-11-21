import AppKit
import ApplicationServices

struct SessionJump {
    let desktop: URL?
    let web: URL?
    private let deviceAvailable: Bool

    init?(card: Card, pairedWebLink: URL? = nil) {
        guard card.origin == .adapter else { return nil }
        let snapshot = card.value
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
        case universalLink(URL)
        case browser(URL)
    }

    func steps(providerRunning: Bool) -> [Step] {
        var result: [Step] = []
        if let web, providerRunning { result.append(.matchingWindow(web)) }
        if let desktop, (providerRunning && deviceAvailable) || web == nil { result.append(.desktop(desktop)) }
        if let web {
            if desktop == nil && providerRunning { result.append(.universalLink(web)) }
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
            case .matchingWindow(let url):
                if Self.raiseMatchingWindow(url,in: apps) { return true }
            case .desktop(let url):
                let appURL = apps.first { $0.bundleIdentifier == "com.openai.codex" }?.bundleURL
                    ?? workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
                if let appURL, await Self.deliver(url,to: appURL) { return true }
            case .universalLink(let url):
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.requiresUniversalLinks = true
                if (try? await workspace.open(url,configuration: configuration)) != nil { return true }
            case .browser(let url):
                // Resolve the user's ordinary HTTPS browser separately from app-associated session links.
                let sample = URL(string: "https://example.com")!
                if let browser = workspace.urlForApplication(toOpen: sample), await Self.deliver(url,to: browser) { return true }
            }
        }
        return false
    }

    @MainActor private static func deliver(_ url: URL,to app: URL) async -> Bool {
        do {
            _ = try await NSWorkspace.shared.open([url],withApplicationAt: app,configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch { return false }
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
