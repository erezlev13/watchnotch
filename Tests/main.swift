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
check(chatJump.steps(providerRunning: true) == [.chatWindow(privateURL),.universalLink(privateURL)],"ChatGPT must prefer its own open window and keep the identical URL on fallback")
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
check(SessionJump.nativeChatURL("app://-/c/" + key) == privateURL, "desktop Work route did not match the conversation")
check(SessionJump.nativeChatURL("https://unrelated.example/c/" + key) == nil, "unrelated URL was accepted")
print("PASS  Exact-session desktop routing, browser fallback, offline, local-only, and fixture handling")

let owlRoot = root.appendingPathComponent("owl-test")
let owlDir = owlRoot.appendingPathComponent("Sessions")
let owlStore = Store(root: owlRoot,directory: owlDir,ticking: false)
let demoPins = owlStore.pinned.map(\.id)
let clock = Date()
check(owlStore.watchedSession == demoPins[0],"equal timestamps must keep stable pin order")
owlStore.tick(now: clock.addingTimeInterval(5))
owlStore.tick(now: clock.addingTimeInterval(10))
check(owlStore.watchedSession == demoPins[1],"owl did not follow new demo activity")

func publishActivity(_ key: String, at time: Date, state: SessionState = .running) throws -> Identity {
    let sample = Snapshot(provider: "Test",sessionID: key,title: "Same title",sentence: "The task is running.",state: state,updatedAt: time)
    try Format.encoder().encode(sample).write(to: owlDir.appendingPathComponent(key + ".json"),options: .atomic)
    owlStore.tick()
    let id = Identity(origin: .adapter,provider: "Test",sessionID: key)
    owlStore.pin(id)
    return id
}
let first = try publishActivity("first",at: clock)
let second = try publishActivity("second",at: clock.addingTimeInterval(2))
check(owlStore.watchedSession == second,"demo or older live session took focus")
_ = try publishActivity("first",at: clock.addingTimeInterval(3),state: .needsInput)
check(owlStore.watchedSession == first,"newer event failed to move the owl")
owlStore.tick()
check(owlStore.watchedSession == first,"quiet poll moved the owl")
_ = try publishActivity("first",at: clock.addingTimeInterval(4),state: .unavailable)
check(owlStore.watchedSession == second,"disconnected session kept the owl")
for id in demoPins + [second] { owlStore.unpin(id) }
check(owlStore.watchedSession == nil,"offline card attracted the owl")
_ = owlStore.addChat("https://chatgpt.com/c/" + UUID().uuidString,title: "Saved conversation")
check(owlStore.watchedSession == nil,"bookmark reported activity")
print("PASS  Owl follows the latest pinned active session, prefers live updates and ignores bookmarks and quiet polls")

let linked = sessions.appendingPathComponent("linked.json")
let outside = root.appendingPathComponent("elsewhere.json")
try Format.encoder().encode(sample).write(to: outside)
try fs.createSymbolicLink(at: linked, withDestinationURL: outside)
let pipe = sessions.appendingPathComponent("pipe.json")
check(mkfifo(pipe.path, 0o600) == 0, "could not create test pipe")
restart.tick()
check(restart.cards[live.id]?.source == nil, "session reader followed a symbolic link")

var observer = local
observer.state = .needsInput
observer.request = req
observer.resultURL = outside
try Format.encoder().encode(observer).write(to: sessions.appendingPathComponent("codex-" + key + ".json"))
restart.tick()
let observed = restart.cards[Identity(origin: .adapter, provider: "Codex", sessionID: key)]!
check(observed.value.request == nil && observed.value.resultURL == nil && observed.value.state == .unavailable, "observer supplied unsupported actions")

let document = root.appendingPathComponent("sample-2.txt")
check(Format.resultViewer(document)?.lastPathComponent == "TextEdit.app", "plain text viewer unavailable")
let alias = root.appendingPathComponent("linked.txt")
try fs.createSymbolicLink(at: alias, withDestinationURL: document)
check(Format.resultViewer(alias) == nil, "accepted a linked result")
try fs.setAttributes([.posixPermissions: 0o700], ofItemAtPath: document.path)
check(Format.resultViewer(document) == nil, "accepted executable result")
check(!Format.webResult(nativeURL) && Format.webResult(privateURL), "result URL scheme validation")
print("PASS  Private snapshot reads, observer capabilities and constrained result viewers")

for screen in [CGFloat(320), 1024, 1440, 1920, 3440] {
    let layout = TileLayout(available: screen)
    check(layout.tileWidth(for: 1) <= 300, "single tile stretched")
    check(layout.rowWidth(for: 1) <= 332, "single tile window stretched")
    check(layout.rowWidth(for: layout.capacity + 3) <= screen, "overflowing panel")
    check(layout.tileWidth(for: layout.capacity + 3) == layout.tileWidth(for: layout.capacity), "shrunk retained pins after display change")
}
check(TileLayout(available: 1920).capacity > TileLayout(available: 1024).capacity, "fixed pin limit")

let workRoot = root.appendingPathComponent("work-activity")
let workStore = Store(root: workRoot, directory: workRoot.appendingPathComponent("Sessions"), ticking: false)
workStore.pinned.forEach { workStore.unpin($0.id) }
let workKey = UUID().uuidString.lowercased()
let workID = Identity(origin: .adapter, provider: "ChatGPT", sessionID: workKey)
check(workStore.addChat("https://chatgpt.com/c/" + workKey, title: "Saved chat"), "failed to pin Work chat")
var workRow = LibraryItem(provider: "ChatGPT", sessionID: workKey, title: "Work test", updated: 123,
                          state: .running, work: true, activityText: "Writing a response")
workStore.updateChatActivity([workRow], desktopRunning: true)
let writing = workStore.cards[workID]!.value
check(writing.state == .running && writing.sentence == "Writing a response" && writing.desktopChat == true,
      "pinned Work chat did not display its live desktop state")
workStore.updateChatActivity([workRow], desktopRunning: true)
check(workStore.cards[workID]?.value.updatedAt == writing.updatedAt, "quiet Work chat changed its activity timestamp")
workRow.state = nil
workRow.activityText = nil
workStore.updateChatActivity([workRow], desktopRunning: true)
check(workStore.cards[workID]?.value.sentence == "ChatGPT stopped reporting activity", "cleared signal falsely implied success")
workRow.state = .ready
workRow.activityText = "A new response is ready"
workStore.updateChatActivity([workRow], desktopRunning: true)
check(workStore.cards[workID]?.value.state == .ready, "unread finished response missed")
workStore.updateChatActivity([], desktopRunning: true)
check(workStore.cards[workID]?.value.desktopChat != true && workStore.cards[workID]?.value.state == .unavailable,
      "missing catalog kept reporting a previous live turn")
print("PASS  Pinned Work activity, stable timestamps and cleared desktop signals")

let chatKey = UUID().uuidString.lowercased()
let chatID = Identity(origin: .adapter, provider: "ChatGPT", sessionID: chatKey)
check(workStore.addChat("https://chatgpt.com/c/" + chatKey, title: "Saved chat"), "failed to pin ordinary Chat")
let chatRow = LibraryItem(provider: "ChatGPT", sessionID: chatKey, title: "Work test", updated: 100)
func checkChatPair(_ chat: LibraryItem, _ work: LibraryItem, running: Bool) {
    workStore.updateChatActivity([chat, work], desktopRunning: running)
    for key in [chatID, workID] {
        check(workStore.cards[key]?.connected == running, "connection did not follow desktop for both pins")
        check(workStore.cards[key]?.value.nativeChatTitle == nil, "duplicate titles could misroute a session")
    }
}
workRow.state = .running
workRow.activityText = "Writing a response"
checkChatPair(chatRow, workRow, running: true)
check(workStore.cards[chatID]?.quietChat == true && workStore.cards[chatID]?.value.state == .ready, "quiet chat was disconnected")
check(workStore.cards[chatID]?.value.sentence == "No active turn reported", "quiet chat claimed a turn")
check(workStore.cards[workID]?.value.state == .running, "ordinary Chat affected Work")
let newer = LibraryItem(provider: "ChatGPT", sessionID: chatKey, title: chatRow.title, updated: 150)
checkChatPair(newer, workRow, running: true)
let changed = workStore.cards[chatID]!
check(changed.value.sentence == "Conversation updated in ChatGPT", "missed update between polls")
check(workStore.watchedSession == chatID, "owl missed ordinary Chat update")
checkChatPair(newer, workRow, running: true)
check(workStore.cards[chatID] == changed, "quiet poll changed chat")
checkChatPair(newer, workRow, running: false)
check(workStore.cards[workID]?.value.state == .unavailable && workStore.watchedSession == nil,
      "cached Work status survived desktop disconnect")
let resumed = Store(root: workRoot, directory: workRoot.appendingPathComponent("Sessions"), ticking: false)
check(resumed.pinned.map(\.id) == [workID, chatID] && resumed.watchedSession == nil, "restart lost pins or replayed cached activity")
resumed.updateChatActivity([newer, workRow], desktopRunning: true)
check(resumed.cards[chatID]?.connected == true && resumed.cards[workID]?.value.state == .running, "failed to reconnect pins")
resumed.updateChatActivity([workRow], desktopRunning: true)
check(resumed.cards[chatID]?.connected == false, "missing chat kept its connection")
print("PASS  Chat and Work pins monitor independently across quiet polls, source changes, disconnect and restart")
