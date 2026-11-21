import AppKit

final class Node: Equatable {
    static func ==(lhs: Node, rhs: Node) -> Bool { lhs === rhs }
    let role: String
    var children: [Node]
    var attributes: [String: String] = [:]
    var classes: [String] = []
    var enabled = true
    var onPress: (() -> Void)?
    init(_ role: String, _ children: [Node] = [], label: String? = nil) {
        self.role = role
        self.children = children
        if let label { attributes[kAXDescriptionAttribute] = label }
    }
}

final class MockSurface: ChatChoiceSurface {
    var roots = [Node]()
    var presses: [Node] = []
    func windows() -> [Node] { roots }
    func string(_ node: Node, _ key: String) -> String? { key == kAXRoleAttribute ? node.role : node.attributes[key] }
    func classes(_ node: Node) -> [String] { node.classes }
    func children(_ node: Node) -> [Node] { node.children }
    func enabled(_ node: Node) -> Bool { node.enabled }
    func press(_ node: Node) -> Bool { presses.append(node); node.onPress?(); return true }
}

func request(_ kind: String, text: String, labels: [String]) -> Node {
    let title = Node("AXStaticText")
    title.attributes[kAXValueAttribute] = text
    let choices = labels.map { Node(kind == "approval" ? "AXButton" : "AXRadioButton", label: $0) }
    let card = Node("AXGroup", [title] + choices)
    card.classes = [kind == "approval" ? "@container/approval-card" : "@container/request-card"]
    return card
}
func document(_ id: String, _ children: [Node]) -> Node {
    let doc = Node("AXWebArea", children)
    doc.attributes[kAXURLAttribute] = "app://-/c/" + id
    return doc
}
let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
let a = request("question", text: "Which color?", labels: ["Red", "Blue"])
let b = request("approval", text: "Allow access to Camera?", labels: ["Allow once", "Deny"])
let d1 = document(first, [a]), d2 = document(second, [b])
let ui = MockSurface()
ui.roots = [Node("AXWindow", [d1]), Node("AXWindow", [d2])]
let reader = ChatChoiceReader(surface: ui)
let both: Set<String> = [first, second]
let start = reader.scan(sessionIDs: both)
precondition(start[first]?.questions?.first?.prompt == "Which color?")
precondition(start[second]?.kind == "approval")
precondition(!reader.respond(sessionID: second, requestID: start[first]!.id, answers: ["selection":"0"]))
precondition(!reader.respond(sessionID: first, requestID: start[first]!.id, answers: ["selection":"Blue"]))
precondition(ui.presses.isEmpty)
a.children[2].onPress = { d1.children = [] }
precondition(reader.respond(sessionID: first, requestID: start[first]!.id, answers: ["selection":"1"]))
precondition(ui.presses == [a.children[2]])
precondition(!reader.respond(sessionID: first, requestID: start[first]!.id, answers: ["selection":"1"]))
// An identically titled replacement approval must obtain a fresh request ID.
let replacement = request("approval", text: "Allow access to Camera?", labels: ["Allow once", "Deny"])
d2.children = [replacement]
precondition(!reader.respond(sessionID: second, requestID: start[second]!.id, answers: ["selection":"0"]))
let next = reader.scan(sessionIDs: both)
precondition(next[second]!.id != start[second]!.id)
replacement.children[2].onPress = { d2.children = [] }
precondition(reader.respond(sessionID: second, requestID: next[second]!.id, answers: ["selection":"1"]))
precondition(ui.presses.last == replacement.children[2])

// Never accept content, embedded sites, duplicated labels, or permanent grant variants.
let article = Node("AXGroup", [a])
article.attributes[kAXSubroleAttribute] = "AXDocumentArticle"
let wrongSite = document(first, [a])
wrongSite.attributes[kAXURLAttribute] = "https://chatgpt.com/c/" + first
d1.children = [article, wrongSite]
precondition(reader.scan(sessionIDs: both).isEmpty)
d1.children = [request("approval", text: "Approve?", labels: ["Always allow", "Deny"])]
precondition(reader.scan(sessionIDs: both).isEmpty)
d1.children = [request("question", text: "Which color?", labels: ["Red", "Red"])]
precondition(reader.scan(sessionIDs: both).isEmpty)
d1.children = [a]
let stale = reader.scan(sessionIDs: both)
d1.attributes[kAXURLAttribute] = "app://-/c/" + second
precondition(!reader.respond(sessionID: first, requestID: stale[first]!.id, answers: ["selection":"0"]))
print("ChatGPT desktop question and approval routing passed")
