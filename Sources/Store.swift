import Foundation
import Combine
import Darwin

final class Store: ObservableObject {
    @Published private(set) var cards: [Identity: Card] = [:]
    @Published private(set) var saved = Saved()
    @Published var notice: String?
    @Published var pinLimit: Int
    @Published private(set) var importedChats: [LibraryItem] = []
    private let root: URL
    let directory: URL
    private var timer: AnyCancellable?
    private var demoStart = Date()
    private var monitors: [String: Process] = [:]
    private var stage = 0
    private let fs = FileManager.default
    private let fixtureTitles = ["Notch companion", "Market research", "Weekly brief", "Market research", "Release notes", "Interview guide"]

    init(root: URL, directory: URL, ticking: Bool = true, displayWidth: CGFloat = 1440) {
        pinLimit = TileLayout(available: displayWidth).capacity
        self.root = root
        self.directory = directory
        do {
            try fs.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fs.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { notice = error.localizedDescription }
        let savedFile = root.appendingPathComponent("selection.json")
        let existing = fs.fileExists(atPath: savedFile.path)
        if existing {
            do { saved = try Format.decoder().decode(Saved.self, from: readPrivateFile(savedFile, limit: 4 * 1024 * 1024)) }
            catch { notice = "Could not load saved pins: " + error.localizedDescription }
        }
        let importedFile = root.appendingPathComponent("chat-library.json")
        if let data = try? readPrivateFile(importedFile, limit: 16 * 1024 * 1024) {
            importedChats = (try? JSONDecoder().decode([LibraryItem].self, from: data)) ?? []
        }
        for var snapshot in saved.lastKnown {
            snapshot.state = .unavailable
            snapshot.request = nil
            if ["Codex", "ChatGPT"].contains(snapshot.provider) { snapshot.resultURL = nil }
            put(Card(value: snapshot, origin: .adapter))
        }
        resetDemo()
        if !existing { saved.pins = Array([fixtureID(0),fixtureID(1),fixtureID(2)].prefix(pinLimit)); persist() }
        tick()
        if ticking {
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        }
    }

    // Validate the opened descriptor so a path change cannot swap in a pipe or a link.
    private func readPrivateFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        return data
    }

    var pinned: [Card] { saved.pins.compactMap { cards[$0] } }
    var watchedSession: Identity? {
        // A replayed demo must never take attention away from a connected session.
        let eligible = pinned.filter { $0.value.state != .unavailable }
        let connected = eligible.filter { $0.origin == .adapter && $0.source != nil }
        let candidates = connected.isEmpty ? eligible.filter { $0.origin == .fixture } : connected
        return candidates.reduce(nil as Card?) { latest, card in
            guard let latest else { return card }
            return card.value.updatedAt > latest.value.updatedAt ? card : latest
        }?.id
    }

    var catalog: [Card] {
        cards.values.sorted { a, b in
            if a.origin != b.origin { return a.origin.rawValue < b.origin.rawValue }
            return (a.value.title, a.value.provider, a.value.sessionID) < (b.value.title, b.value.provider, b.value.sessionID)
        }
    }
    private func put(_ card: Card) { if cards[card.id] != card { cards[card.id] = card } }
    private func persist() {
        saved.lastKnown = pinned.filter { $0.origin == .adapter }.map(\.value)
        do { try Format.encoder().encode(saved).write(to: root.appendingPathComponent("selection.json"), options: .atomic) }
        catch { notice = "Could not save pins: " + error.localizedDescription }
    }
    func saveChatLibrary(_ items: [LibraryItem]) throws {
        var merged: [Identity: LibraryItem] = [:]
        for item in importedChats + items where item.provider == "ChatGPT" && UUID(uuidString: item.sessionID) != nil {
            merged[item.id] = item
        }
        let ordered = merged.values.sorted { $0.updated > $1.updated }
        let data = try JSONEncoder().encode(ordered)
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try data.write(to: root.appendingPathComponent("chat-library.json"), options: .atomic)
        importedChats = ordered
    }

    func pin(_ id: Identity) {
        guard cards[id] != nil, !saved.pins.contains(id) else { return }
        guard saved.pins.count < pinLimit else { notice = "Unpin a session to make room."; return }
        saved.pins.append(id)
        persist()
    }
    func unpin(_ id: Identity) {
        saved.pins.removeAll { $0 == id }
        saved.watches?.removeAll { $0 == id }
        if id.provider == "Codex", let process = monitors.removeValue(forKey: id.sessionID), process.isRunning { process.terminate() }
        persist()
    }

    func addChat(_ text: String, title: String) -> Bool {
        guard let (id, url) = Format.chatLink(text) else {
            notice = "Paste a ChatGPT conversation link containing /c/ and its conversation ID."
            return false
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 120, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            notice = "Use a single-line title up to 120 characters long."
            return false
        }
        let snapshot = Snapshot(provider: "ChatGPT", sessionID: id, title: name.isEmpty ? "ChatGPT conversation" : name,
                                sentence: "Open this conversation to check its latest reply.", state: .unavailable,
                                updatedAt: Date(), sessionURL: url)
        let file = directory.appendingPathComponent("chatgpt-" + id + ".json")
        let card = Card(value: snapshot, origin: .adapter, source: file)
        guard saved.pins.contains(card.id) || saved.pins.count < pinLimit else { notice = "Unpin a session to make room."; return false }
        do { try Format.encoder().encode(snapshot).write(to: file, options: .atomic) }
        catch { notice = error.localizedDescription; return false }
        put(card)
        pin(card.id)
        notice = nil
        return true
    }

    func watchCodex(_ input: String, webLink: String = "") -> Bool {
        let supplied = webLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = SessionJump.webLink(supplied)
        guard supplied.isEmpty || fallback != nil else {
            notice = "Enter the private ChatGPT conversation or Codex task URL for this thread."
            return false
        }
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "codex://threads/"
        let raw = address.hasPrefix(prefix) ? String(address.dropFirst(prefix.count)) : address
        guard let uuid = UUID(uuidString: raw) else {
            notice = "Enter a Codex thread UUID or a codex://threads/ link."
            return false
        }
        let id = Identity(origin: .adapter, provider: "Codex", sessionID: uuid.uuidString.lowercased())
        guard saved.pins.contains(id) || saved.pins.count < pinLimit else { notice = "Unpin a session to make room."; return false }
        guard let script = Bundle.main.url(forResource: "monitor", withExtension: "py") else {
            notice = "The Codex monitor is missing from this app bundle."
            return false
        }
        if monitors[id.sessionID]?.isRunning == true {
            saveWebLink(fallback, for: id)
            pin(id)
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-S", script.path, address]
        var environment = ProcessInfo.processInfo.environment
        environment["NOTCH_SESSION_DIR"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { notice = "Could not launch the Codex monitor: " + error.localizedDescription; return false }
        saveWebLink(fallback, for: id)
        monitors[id.sessionID] = process
        saved.watches = Array(Set((saved.watches ?? []) + [id]))
        let url = address.hasPrefix(prefix) ? URL(string: address) : nil
        if cards[id] == nil {
            let value = Snapshot(provider: "Codex", sessionID: id.sessionID, title: "Codex thread",
                                 sentence: "Waiting for the local Codex service to identify this thread.", state: .unavailable, updatedAt: Date(), sessionURL: url)
            put(Card(value: value, origin: .adapter))
        }
        pin(id)
        persist()
        process.terminationHandler = { [weak self] worker in
            DispatchQueue.main.async {
                guard let self, self.monitors[id.sessionID] === worker else { return }
                self.monitors.removeValue(forKey: id.sessionID)
                if worker.terminationStatus != 0 {
                    self.notice = "The Codex monitor stopped; check that the thread ID exists in your local Codex account."
                }
            }
        }
        return true
    }

    private func saveWebLink(_ url: URL?, for id: Identity) {
        guard let url else { return }
        if saved.webLinks == nil { saved.webLinks = [:] }
        saved.webLinks?[id.sessionID] = url
        persist()
    }

    func stopMonitors() {
        for process in monitors.values where process.isRunning { process.terminate() }
        monitors.removeAll()
    }

    private func fixtureID(_ n: Int) -> Identity {
        Identity(origin: .fixture, provider: [0,3,4].contains(n) ? "Codex" : "ChatGPT", sessionID: "demo-\(n)")
    }
    func resetDemo() {
        stage = 0
        demoStart = Date()
        let sentences = ["The layout check is running on the sample window.", "Three sample vendors are being compared.", "The weekly brief is ready to review.", "The pricing table is ready for review.", "The release notes are ready to review.", "The interview guide is ready to review."]
        for n in fixtureTitles.indices {
            let id = fixtureID(n)
            let sample = Snapshot(provider: id.provider, sessionID: id.sessionID, title: fixtureTitles[n],
                                  sentence: sentences[n], state: n < 2 ? .running : .ready, updatedAt: demoStart)
            var card = Card(value: sample, origin: .fixture)
            if n >= 2 { card.value.resultURL = writeResult(n) }
            put(card)
        }
    }
    private func writeResult(_ n: Int) -> URL? {
        let url = root.appendingPathComponent("sample-\(n).txt")
        let body = ["Layout check passed on the synthetic window.", "Vendor Elm offers the shortest sample lead time.", "The sample team reviewed three designs and picked the compact panel.", "Vendor Elm: 2 days. Vendor Ash: 4 days. Vendor Oak: 6 days.", "Added pinning and one-time decisions.", "Ask how the participant tracks a task while switching apps."]
        do { try ("Fixture result — " + fixtureTitles[n] + "\n\n" + body[n] + "\n").write(to: url, atomically: true, encoding: .utf8); return url }
        catch { notice = error.localizedDescription; return nil }
    }

    func tick(now: Date = Date()) {
        if stage == 0, now.timeIntervalSince(demoStart) >= 4, var card = cards[fixtureID(0)] {
            card.value.request = PendingRequest(id: UUID().uuidString, action: "Save the sample layout report", reason: "This creates a local text file you can review.", expiresAt: now.addingTimeInterval(120))
            card.value.sentence = "The layout check needs permission to save its report."
            card.value.state = .needsInput
            card.value.updatedAt = now
            put(card)
            stage = 1
        }
        if stage == 1, now.timeIntervalSince(demoStart) >= 9, var card = cards[fixtureID(1)] {
            card.value.request = PendingRequest(id: UUID().uuidString, action: "Export the vendor shortlist", reason: "This saves the comparison as a local text file.", expiresAt: now.addingTimeInterval(120))
            card.value.sentence = "The vendor shortlist is ready to export."
            card.value.state = .needsInput
            card.value.updatedAt = now
            put(card)
            stage = 2
        }
        refreshAdapters(now: now)
        for var card in Array(cards.values) where card.value.request.map({ $0.expiresAt <= now }) == true {
            card.value.request = nil
            card.value.state = .unavailable
            card.value.sentence = "The decision expired before a response was delivered."
            put(card)
        }
    }

    // Codex holds this advisory lock through reconnects. The kernel releases it if the monitor crashes.
    private func hasCodexWriter(_ file: URL) -> Bool {
        let fd = open(file.deletingPathExtension().appendingPathExtension("lock").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    private func refreshAdapters(now: Date) {
        let before = pinned.filter { $0.origin == .adapter }.map(\.value)
        let files = (try? fs.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var seen = Set<Identity>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? readPrivateFile(file, limit: 262144), var snapshot = try? Format.decoder().decode(Snapshot.self, from: data),
                  !snapshot.sessionID.isEmpty, !snapshot.title.isEmpty, !snapshot.sentence.isEmpty else { continue }
            if ["Codex", "ChatGPT"].contains(snapshot.provider) {
                guard let uuid = UUID(uuidString: snapshot.sessionID),
                      snapshot.sessionID == uuid.uuidString.lowercased(),
                      file.lastPathComponent == snapshot.provider.lowercased() + "-" + snapshot.sessionID + ".json" else { continue }
                // The bundled adapters only report status and never issue approvals or results.
                snapshot.request = nil
                snapshot.resultURL = nil
                if snapshot.provider == "ChatGPT" || !hasCodexWriter(file) { snapshot.state = .unavailable }
            }
            if snapshot.state != .needsInput { snapshot.request = nil }
            if let req = snapshot.request {
                if req.expiresAt <= now {
                    snapshot.request = nil
                    snapshot.state = .unavailable
                    snapshot.sentence = "The decision expired before a response was delivered."
                } else if fs.fileExists(atPath: file.path + ".decision") {
                    snapshot.request = nil
                    snapshot.sentence = "Your decision is waiting for the provider to confirm."
                }
            }
            let card = Card(value: snapshot, origin: .adapter, source: file)
            seen.insert(card.id)
            put(card)
        }
        for var card in Array(cards.values) where card.origin == .adapter && !seen.contains(card.id) {
            card.source = nil
            card.value.state = .unavailable
            card.value.request = nil
            put(card)
        }
        if before != pinned.filter({ $0.origin == .adapter }).map(\.value) { persist() }
    }

    @discardableResult
    func decide(_ id: Identity, requestID: String, allow: Bool) -> Bool {
        tick()
        guard var card = cards[id], let req = card.value.request, card.value.state == .needsInput,
              req.id == requestID, req.expiresAt > Date() else { notice = "This request is no longer pending."; return false }
        if card.origin == .fixture {
            guard let index = fixtureTitles.indices.first(where: { fixtureID($0) == id }) else { return false }
            card.value.resultURL = allow ? writeResult(index) : nil
            let document = index == 1 ? "vendor shortlist" : "layout report"
            if allow && card.value.resultURL == nil { return false }
            card.value.sentence = allow ? "The sample " + document + " is ready to open." : "You declined to save the sample " + document + "."
            card.value.state = .ready
            card.value.updatedAt = Date()
        } else {
            guard let file = card.source else { return false }
            let decision = Decision(provider: id.provider, sessionID: id.sessionID, requestID: req.id, decision: allow ? "allowOnce" : "deny")
            do {
                try Format.encoder().encode(decision).write(to: file.appendingPathExtension("decision"), options: .withoutOverwriting)
                card.value.sentence = "Your decision is waiting for the provider to confirm."
            } catch { notice = "Could not deliver the decision: " + error.localizedDescription; return false }
        }
        card.value.request = nil
        put(card)
        return true
    }
}
