import AppKit
import ApplicationServices

// Drive the same composer and Send button the user sees. Keep all writes bound
// to controls descended from the desktop document for this conversation UUID.
@MainActor
struct DesktopChatReply {
    enum Outcome: Equatable {
        case submitted, permission, unavailable, existingDraft, composerUnavailable, unconfirmed

        var message: String {
            switch self {
            case .submitted: return "Submitted in ChatGPT"
            case .permission: return "Allow watchnotch in System Settings → Privacy & Security → Accessibility, then send again."
            case .unavailable: return "Open this conversation in ChatGPT desktop, then send again."
            case .existingDraft: return "There’s already a different draft in ChatGPT."
            case .composerUnavailable: return "ChatGPT’s composer isn’t ready. Your draft is kept."
            case .unconfirmed: return "Check the conversation before sending again."
            }
        }
    }

    let target: URL
    private let app: NSRunningApplication

    init?(target: URL) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else { return nil }
        self.target = target
        self.app = app
    }

    private func string(_ node: AXUIElement, _ name: String) -> String? {
        SessionJump.attribute(node, name) as? String
    }

    private func children(_ node: AXUIElement) -> [AXUIElement] {
        SessionJump.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func isTarget(_ node: AXUIElement) -> Bool {
        guard string(node, kAXRoleAttribute) == "AXWebArea",
              let raw = SessionJump.attribute(node, kAXURLAttribute),
              let address = (raw as? URL)?.absoluteString ?? raw as? String else { return false }
        return address.hasPrefix("app://-/") && SessionJump.nativeChatURL(address) == target
    }

    // Stop at other web documents, dialogs, navigation and message articles.
    // The composer and its submit control belong to the app chrome.
    private func matches(in root: AXUIElement, _ predicate: (AXUIElement, String) -> Bool) -> [AXUIElement] {
        var queue = [root], index = 0, result: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.9)
        while index < queue.count {
            guard index < 1400, Date() < deadline else { return [] }
            let node = queue[index]
            index += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if predicate(node, role) { result.append(node); continue }
            if index > 1 && (["AXWebArea", "AXSheet", "AXTextArea", "AXTextField", "AXStaticText", "AXLink", "AXButton"].contains(role) ||
                ["AXDocumentArticle", "AXLandmarkNavigation", "AXApplicationDialog", "AXSidebar"].contains(string(node, kAXSubroleAttribute) ?? "")) { continue }
            queue.append(contentsOf: children(node))
        }
        return result
    }

    private func document() -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let windows = SessionJump.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows {
            if let doc = matches(in: window, { node, role in role == "AXWebArea" && isTarget(node) }).first { return doc }
        }
        return nil
    }

    private func parent(_ node: AXUIElement) -> AXUIElement? {
        guard let raw = SessionJump.attribute(node, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func belongsToTarget(_ node: AXUIElement) -> Bool {
        var current: AXUIElement? = node
        for _ in 0..<36 {
            guard let element = current else { return false }
            if string(element, kAXRoleAttribute) == "AXWebArea" { return isTarget(element) }
            current = parent(element)
        }
        return false
    }

    private func editor(in doc: AXUIElement) -> AXUIElement? {
        let editors = matches(in: doc) { node, role in
            guard ["AXTextArea", "AXTextField"].contains(role) else { return false }
            let classes = SessionJump.attribute(node, "AXDOMClassList") as? [String] ?? []
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute].compactMap { string(node, $0) }
            let composerLabels = ["Ask ChatGPT", "Message ChatGPT", "Work with ChatGPT"]
            return classes.contains("ProseMirror") || labels.contains(where: composerLabels.contains)
        }
        return editors.count == 1 ? editors[0] : nil
    }

    private func sendButton(near editor: AXUIElement) -> AXUIElement? {
        var current = parent(editor)
        for _ in 0..<12 {
            guard let group = current else { return nil }
            let role = string(group, kAXRoleAttribute) ?? ""
            guard role != "AXWebArea", string(group, kAXSubroleAttribute) != "AXLandmarkMain" else { return nil }
            let buttons = matches(in: group) { node, role in
                guard role == "AXButton" else { return false }
                return [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                    ["Send", "Send message"].contains(string(node, $0) ?? "")
                }
            }
            if !buttons.isEmpty { return buttons.count == 1 ? buttons[0] : nil }
            current = parent(group)
        }
        return nil
    }

    func checkOpenComposer() -> String {
        guard AXIsProcessTrusted() else { return "Accessibility permission required for watchnotch" }
        enableAccessibility()
        guard let doc = document() else { return "Open the pinned conversation in ChatGPT desktop" }
        guard let input = editor(in: doc), belongsToTarget(input) else { return "Conversation matched, composer unavailable" }
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &writable) == .success,
              writable.boolValue else { return "Conversation matched, composer is read-only" }
        return "Matched conversation and writable desktop composer"
    }

    private func enableAccessibility() {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func submit(_ draft: String, title: String?) async -> Outcome {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return .permission }
        enableAccessibility()
        var doc = document()
        if doc == nil {
            guard SessionJump.selectChat(target, title: title, in: app) else { return .unavailable }
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                doc = document()
                if doc != nil { break }
            }
        }
        guard let doc, isTarget(doc), let editor = editor(in: doc) else { return .composerUnavailable }
        return await Self.deliver(draft, read: {
            guard self.belongsToTarget(editor) else { return nil }
            return self.string(editor, kAXValueAttribute)
        }, write: {
            guard self.belongsToTarget(editor), self.string(editor, kAXValueAttribute) == "" else { return false }
            return AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, draft as CFString) == .success
        }, press: {
            guard let button = self.sendButton(near: editor),
                  SessionJump.attribute(button, kAXEnabledAttribute) as? Bool == true else { return .waiting }
            guard self.belongsToTarget(button), self.belongsToTarget(editor),
                  self.string(editor, kAXValueAttribute) == draft else { return .changed }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? .pressed : .uncertain
        })
    }

    enum Press { case waiting, changed, pressed, uncertain }

    // A successful AX press may time out after ChatGPT has already processed it.
    // Only retry lookups. Once a press is attempted, observe the same editor for acknowledgement.
    static func deliver(_ draft: String, read: () -> String?, write: () -> Bool, press: () -> Press,
                        wait: () async -> Void = { try? await Task.sleep(nanoseconds: 120_000_000) }) async -> Outcome {
        guard let existing = read() else { return .composerUnavailable }
        guard existing.isEmpty || existing == draft else { return .existingDraft }
        if existing.isEmpty && !write() { return .composerUnavailable }
        for _ in 0..<8 {
            await wait()
            guard read() == draft else { return .composerUnavailable }
            switch press() {
            case .waiting: continue
            case .changed: return .composerUnavailable
            case .uncertain: return .unconfirmed
            case .pressed:
                for _ in 0..<10 {
                    await wait()
                    if read() == "" { return .submitted }
                }
                return .unconfirmed
            }
        }
        return .composerUnavailable
    }
}
