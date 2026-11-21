// A read-only check. It never requests permission or prints conversation content.
import AppKit
import ApplicationServices

let trusted = AXIsProcessTrusted()
print("Accessibility granted to this process: \(trusted)")
guard trusted else { exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
    print("ChatGPT desktop process unavailable.")
    exit(3)
}
let target = AXUIElementCreateApplication(app.processIdentifier)
var value: CFTypeRef?
let status = AXUIElementCopyAttributeValue(target, kAXWindowsAttribute as CFString, &value)
print("Window lookup result: \(status.rawValue)")
guard status == .success, let windows = value as? [AXUIElement] else { exit(4) }
print("Accessible windows: \(windows.count)")
print("App is frontmost: \(app.isActive)")
// Enumerate attribute names only. Fetching values could expose unrelated sessions.
for (index, window) in windows.enumerated() {
    var attributes: CFArray?
    let result = AXUIElementCopyAttributeNames(window, &attributes)
    guard result == .success, let names = attributes as? [String] else { continue }
    print("Window \(index + 1) declares title: \(names.contains(kAXTitleAttribute as String)), identifier: \(names.contains(kAXIdentifierAttribute as String)), document: \(names.contains(kAXDocumentAttribute as String))")
}
