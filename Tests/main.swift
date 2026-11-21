import Foundation

func check(_ condition: @autoclosure () -> Bool, _ detail: String) {
    if !condition() { fatalError(detail) }
}

let fs = FileManager.default
let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fs.removeItem(at: root) }
let sessions = root.appendingPathComponent("Sessions")
let store = Store(root: root, directory: sessions, ticking: false)
let initial = store.pinned
check(initial.count == 3,"three initial demo cards")
let id = initial[0].id
store.tick(now: Date().addingTimeInterval(5))
let req = store.cards[id]!.value.request!
store.decide(id, requestID: req.id, allow: true)
let completed = store.cards[id]!.value
check(completed.state == .ready && completed.resultURL.map { fs.fileExists(atPath: $0.path) } == true,"allow creates a local result")
store.decide(id, requestID: req.id, allow: false)
check(store.cards[id]!.value == completed,"duplicate decision changed result")
store.resetDemo()
store.tick(now: Date().addingTimeInterval(5))
store.decide(id, requestID: store.cards[id]!.value.request!.id, allow: false)
check(store.cards[id]!.value.resultURL == nil,"denial exposed result")
store.resetDemo()
store.tick(now: Date().addingTimeInterval(5))
let stale = store.cards[id]!.value.request!.id
store.tick(now: Date().addingTimeInterval(200))
store.decide(id,requestID: stale,allow: true)
check(store.cards[id]!.value.state == .unavailable && store.cards[id]!.value.request == nil,"expired request remained active")
store.resetDemo()
store.tick(now: Date().addingTimeInterval(10))
let research = initial[1].id
let researchRequest = store.cards[research]!.value.request!
let layoutRequest = store.cards[id]!.value.request!
let quiet = store.cards[initial[2].id]!
store.decide(id,requestID: researchRequest.id,allow: false)
check(store.cards[id]!.value.request == layoutRequest,"wrong session consumed a decision")
store.decide(id,requestID: layoutRequest.id,allow: false)
check(store.cards[research]!.value.request == researchRequest,"one decision removed another session's controls")
store.decide(research,requestID: researchRequest.id,allow: true)
check(store.cards[research]!.value.resultURL?.lastPathComponent == "sample-1.txt","approval wrote another session's report")
check(store.cards[initial[2].id] == quiet,"unrelated status or timestamp changed")
let a = UUID().uuidString, b = UUID().uuidString
for uuid in [a,b] {
    check(store.addChat("https://chatgpt.com/c/" + uuid, title: "Same topic"),"bookmark registration failed")
}
check(store.pinned.count == 5 && Set(store.pinned.map(\.id)).count == 5,"duplicate titles collided")
check(!store.addChat("https://chatgpt.com/c/" + UUID().uuidString,title: "Overflow"),"cap exceeded")
check(!store.addChat("https://chatgpt.com.example.com/c/" + a,title: "Bogus"),"accepted unrelated host")
check(!store.addChat("https://chatgpt.com/share/" + a,title: "Public share"),"accepted shared conversation")
let restart = Store(root: root, directory: sessions, ticking: false)
check(restart.pinned.map(\.id) == store.pinned.map(\.id),"lost pin order on restart")
restart.unpin(id)
let snapshotFile = sessions.appendingPathComponent("synthetic.json")
let sample = Snapshot(provider: "Test",sessionID: "test-1",title: "Independent source",sentence: "A test choice is pending.",state: .needsInput,updatedAt: Date(),request: req)
try Format.encoder().encode(sample).write(to: snapshotFile,options: .atomic)
restart.tick()
let live = restart.catalog.first { $0.value.sessionID == "test-1" }!
restart.pin(live.id)
restart.decide(live.id,requestID: "wrong-id",allow: false)
let decisionFile = snapshotFile.appendingPathExtension("decision")
check(!fs.fileExists(atPath: decisionFile.path),"misrouted decision")
restart.decide(live.id,requestID: req.id,allow: true)
let decision = try Format.decoder().decode(Decision.self,from: Data(contentsOf: decisionFile))
check(decision.requestID == req.id && decision.provider == "Test" && decision.sessionID == "test-1" && decision.decision == "allowOnce","incorrect decision identity")
restart.decide(live.id,requestID: req.id,allow: false)
check(try! Format.decoder().decode(Decision.self,from: Data(contentsOf: decisionFile)).decision == "allowOnce","duplicate replaced decision")
try fs.removeItem(at: snapshotFile)
restart.tick()
check(restart.cards[live.id]!.value.state == .unavailable && restart.cards[live.id]!.value.request == nil,"disconnected request remained active")
let restored = Store(root: root,directory: sessions,ticking: false)
check(restored.pinned.contains(where: { $0.id == live.id && $0.value.state == .unavailable }),"disconnected pin lost after restart")
print("PASS  Pin cap and order, stable identity, source import, fixture transitions and results, approval routing, duplicates, expiry, disconnect and restart")

let key = UUID().uuidString.lowercased()
let privateURL = URL(string: "https://chatgpt.com/c/" + key)!
let nativeURL = URL(string: "codex://threads/" + key)!
let cloudURL = URL(string: "https://chatgpt.com/codex/tasks/task_example")!
var source = Snapshot(provider: "ChatGPT",sessionID: key,title: "Same title",sentence: "Ready.",state: .ready,updatedAt: Date(),sessionURL: privateURL)
let chatJump = SessionJump(card: Card(value: source,origin: .adapter))!
check(chatJump.steps(providerRunning: true) == [.matchingWindow(privateURL),.universalLink(privateURL),.browser(privateURL)],"ChatGPT must prefer its own open window and keep the identical URL on fallback")
check(chatJump.steps(providerRunning: false) == [.browser(privateURL)],"closed ChatGPT should use the browser")
check(SessionJump(card: Card(value: source,origin: .fixture)) == nil,"fixture exposed real navigation")
source.sessionURL = URL(string: "https://chatgpt.com/c/" + UUID().uuidString)!
check(SessionJump(card: Card(value: source,origin: .adapter)) == nil,"wrong conversation identity")
var local = Snapshot(provider: "Codex",sessionID: key,title: "Same title",sentence: "Working.",state: .running,updatedAt: Date(),resultURL: root)
let paired = SessionJump(card: Card(value: local,origin: .adapter),pairedWebLink: cloudURL)!
check(paired.steps(providerRunning: true) == [.matchingWindow(cloudURL),.desktop(nativeURL),.browser(cloudURL)],"paired Codex routing order")
check(paired.steps(providerRunning: false) == [.browser(cloudURL)],"closed Codex should use its saved web address")
local.state = .unavailable
check(SessionJump(card: Card(value: local,origin: .adapter),pairedWebLink: cloudURL)!.steps(providerRunning: true) == [.matchingWindow(cloudURL),.browser(cloudURL)],"offline local runtime should fall back")
check(SessionJump(card: Card(value: local,origin: .adapter))!.steps(providerRunning: false) == [.desktop(nativeURL)],"local-only UUID must open its own native thread")
check(SessionJump.webLink("https://unrelated.example/codex/tasks/task_123") == nil,"unexpected web destination")
print("PASS  Exact-session desktop routing, browser fallback, offline, local-only, and fixture handling")
