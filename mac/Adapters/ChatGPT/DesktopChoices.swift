import AppKit
import ApplicationServices

// Read only the native request widget in documents matching pinned conversation IDs.
// Keep the live controls in memory so an old notification can never press a replacement.
protocol ChatChoiceSurface {
    associatedtype Node: Equatable
    func windows() -> [Node]
    func string(_ node: Node, _ attribute: String) -> String?
    func classes(_ node: Node) -> [String]
    func children(_ node: Node) -> [Node]
    func enabled(_ node: Node) -> Bool
    func press(_ node: Node) -> Bool
}

struct ChatChoiceAX: ChatChoiceSurface {
    func windows() -> [AXUIElement] {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }
    func string(_ node: AXUIElement, _ key: String) -> String? {
        let value = attribute(node, key)
        return (value as? URL)?.absoluteString ?? value as? String
    }
    func classes(_ node: AXUIElement) -> [String] { attribute(node, "AXDOMClassList") as? [String] ?? [] }
    func children(_ node: AXUIElement) -> [AXUIElement] { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    func enabled(_ node: AXUIElement) -> Bool { attribute(node, kAXEnabledAttribute) as? Bool == true }
    func press(_ node: AXUIElement) -> Bool { AXUIElementPerformAction(node, kAXPressAction as CFString) == .success }
}

typealias DesktopChoices = ChatChoiceReader<ChatChoiceAX>

extension ChatChoiceReader where Surface == ChatChoiceAX {
    convenience init() { self.init(surface: ChatChoiceAX()) }
}

final class ChatChoiceReader<Surface: ChatChoiceSurface> {
    typealias Node = Surface.Node
    private let surface: Surface
    init(surface: Surface) { self.surface = surface }

    private struct Widget: Equatable {
        let document: Node
        let root: Node
        let kind: String
        let prompt: String
        let labels: [String]
        let descriptions: [String?]
        let controls: [Node]
    }
    private struct Entry {
        let widget: Widget
        let request: PendingRequest
    }
    private var entries: [String: Entry] = [:]
    private var pressed: [String: Widget] = [:]

    private func role(_ node: Node) -> String { surface.string(node, kAXRoleAttribute) ?? "" }

    private func chromeOnly(_ node: Node, role: String) -> Bool {
        let excluded = ["AXDocumentArticle", "AXLandmarkNavigation", "AXSidebar", "AXTabGroup",
                        "AXOutline", "AXLink", "AXTextField", "AXTextArea", "AXStaticText", "AXButton"]
        return !excluded.contains(role) && !excluded.contains(surface.string(node, kAXSubroleAttribute) ?? "")
    }

    // Discard partial scans on timeout or excessive depth so incomplete context cannot
    // be treated as a valid question, a unique match or a confirmed dismissal.
    private func walk(_ nodes: [Node], deadline: Date, visit: (Node, String) -> Bool) -> Bool {
        var stack = Array(nodes.reversed())
        var visited = 0
        while let node = stack.popLast() {
            guard Date() < deadline, visited < 1800 else { return false }
            visited += 1
            let r = role(node)
            guard !r.isEmpty else { return false }
            if visit(node, r) { stack.append(contentsOf: surface.children(node).reversed()) }
        }
        return true
    }

    private func chatID(_ document: Node) -> String? {
        guard let raw = surface.string(document, kAXURLAttribute),
              raw.hasPrefix("app://-/"), let url = SessionJump.nativeChatURL(raw),
              let uuid = UUID(uuidString: url.lastPathComponent) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func inspect(_ root: Node, document: Node, kind: String, deadline: Date) -> Widget? {
        var text: [String] = [], controls: [Node] = [], labels: [String] = []
        var descriptions: [String?] = []
        var unsupported = false
        let scanned = walk(surface.children(root), deadline: deadline) { node, r in
            if ["AXWebArea", "AXDocumentArticle", "AXSheet"].contains(r) { unsupported = true; return false }
            if r == "AXCheckBox" { unsupported = true; return false }
            if r == "AXStaticText" {
                if let s = surface.string(node, kAXValueAttribute), !s.isEmpty { text.append(s) }
                return false
            }
            // User-entered drafts and selector menus are outside the decision.
            if ["AXTextField","AXTextArea","AXPopUpButton","AXMenuButton"].contains(r) { return false }
            guard r == "AXButton" || r == "AXRadioButton" else { return true }
            let name = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { surface.string(node, $0) }
                .first { !$0.isEmpty } ?? ""
            if kind == "question" && r == "AXRadioButton" {
                guard !name.isEmpty, surface.enabled(node) else { unsupported = true; return false }
                labels.append(name)
                let detail = surface.string(node, kAXHelpAttribute)
                guard (detail?.count ?? 0) <= 1024 else { unsupported = true; return false }
                descriptions.append(detail)
                controls.append(node)
            } else if kind == "approval" && r == "AXButton" {
                // The native card may append a keyboard shortcut. Reject unfamiliar
                // variants, especially persistent grants and dropdown menu actions.
                let variants = [
                    "Allow once": ["Allow once", "Allow once Enter", "Allow once Return", "Allow once ↵", "Allow once ⏎", "Allow once ⌤"],
                    "Deny": ["Deny", "Deny Escape", "Deny Esc", "Deny ESC", "Deny ⎋"]
                ]
                if let label = variants.first(where: { $0.value.contains(name) })?.key, surface.enabled(node) {
                    labels.append(label)
                    descriptions.append(nil)
                    controls.append(node)
                }
            }
            return false
        }
        guard scanned, !unsupported, !labels.isEmpty, Set(labels).count == labels.count,
              labels.allSatisfy({ $0.count <= 512 }), chatID(document) != nil else { return nil }
        if kind == "approval", Set(labels) != Set(["Allow once", "Deny"]) { return nil }
        let prompt = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 8192 else { return nil }
        return Widget(document: document, root: root, kind: kind, prompt: prompt, labels: labels, descriptions: descriptions, controls: controls)
    }

    // A rendered request can be addressed independently in each open document.
    private func widgets(_ ids: Set<String>) -> [String: [Widget]] {
        guard !ids.isEmpty else { return [:] }
        let deadline = Date().addingTimeInterval(1.5)
        var documents: [String: [Node]] = [:]
        guard walk(surface.windows(), deadline: deadline, visit: { node, r in
            if r == "AXWebArea" {
                if let id = chatID(node), ids.contains(id) { documents[id, default: []].append(node) }
                return false
            }
            return chromeOnly(node, role: r)
        }) else { return [:] }
        var result: [String: [Widget]] = [:]
        for (id, docs) in documents where docs.count == 1 {
            let doc = docs[0]
            var found: [Widget] = []
            var unreadable = false
            let complete = walk(surface.children(doc), deadline: deadline) { node, r in
                guard r != "AXWebArea", chromeOnly(node, role: r) else { return false }
                let classes = surface.classes(node)
                let approval = classes.contains("@container/approval-card")
                if approval || classes.contains("@container/request-card") {
                    if let widget = inspect(node, document: doc, kind: approval ? "approval" : "question", deadline: deadline) {
                        found.append(widget)
                    } else { unreadable = true }
                    return false
                }
                return true
            }
            if complete, !unreadable, chatID(doc) == id { result[id] = found }
        }
        return result
    }

    func scan(sessionIDs: Set<String>) -> [String: PendingRequest] {
        let ids = Set(sessionIDs.map { $0.lowercased() })
        pressed = pressed.filter { ids.contains($0.key) }
        let found = widgets(ids)
        var next: [String: Entry] = [:]
        for (id, candidates) in found {
            if let prior = pressed[id] {
                // Discard the exact action once. A redraw of the same card can
                // replace its nodes while leaving the original decision pending.
                if candidates.contains(where: { $0.kind == prior.kind && $0.prompt == prior.prompt && $0.labels == prior.labels }) { continue }
                pressed[id] = nil
            }
            guard let widget = candidates.first else { continue }
            if let existing = entries[id], existing.widget == widget, existing.request.expiresAt.timeIntervalSinceNow > 5 {
                next[id] = existing
                continue
            }
            let options = widget.labels.enumerated().map {
                RequestOption(id: String($0.offset), label: $0.element, description: widget.descriptions[$0.offset])
            }
            let q = RequestQuestion(id: "selection", prompt: widget.prompt, options: options)
            let request = PendingRequest(id: UUID().uuidString, action: widget.prompt, reason: "",
                                         expiresAt: Date().addingTimeInterval(120), route: "chatDesktop",
                                         kind: widget.kind, questions: [q])
            next[id] = Entry(widget: widget, request: request)
        }
        entries = next
        return next.mapValues(\.request)
    }

    func respond(sessionID: String, requestID: String, answers: [String: String]) -> Bool {
        let id = sessionID.lowercased()
        guard let entry = entries[id], entry.request.id == requestID, entry.request.expiresAt > Date(),
              entry.request.accepts(answers), let key = answers["selection"], let index = Int(key),
              let current = widgets([id])[id]?.first, current == entry.widget,
              surface.enabled(current.controls[index]), chatID(current.document) == id else { return false }
        entries[id] = nil
        pressed[id] = current
        guard surface.press(current.controls[index]) else { return false }
        // A single-select in ChatGPT advances/submits after its selection animation.
        // Observe the change. Never click a second action or retry an uncertain press.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.10)
            if let visible = widgets([id])[id],
               !visible.contains(where: { $0.kind == current.kind && $0.prompt == current.prompt && $0.labels == current.labels }) { return true }
        }
        return false
    }
}
