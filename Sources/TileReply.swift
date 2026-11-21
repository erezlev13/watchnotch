import AppKit
import SwiftUI

final class TileReplies: ObservableObject {
    @Published var drafts: [Identity: String] = [:]
    @Published private(set) var busy = Set<Identity>()
    @Published private(set) var feedback: [Identity: String] = [:]
    @Published private(set) var checkBeforeRetry = Set<Identity>()

    private var desktopReplyInProgress = false

    static func usesHandoff(_ card: Card, needsReview: Bool) -> Bool {
        guard card.origin == .adapter else { return false }
        if needsReview || card.value.state == .needsInput || card.value.state == .unavailable { return true }
        if card.value.provider == "ChatGPT" { return card.value.desktopChat != true }
        return card.value.provider != "Codex"
    }

    @MainActor func submit(_ card: Card, jump: SessionJump?) async {
        let id = card.id
        guard let draft = drafts[id], !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        if card.origin == .fixture {
            drafts[id] = nil
            feedback[id] = "Demo reply received"
            return
        }
        if Self.usesHandoff(card, needsReview: checkBeforeRetry.contains(id)) {
            await copyAndOpen(card, jump: jump)
            return
        }
        guard draft.utf8.count <= 65536 else { feedback[id] = "Reply exceeds 64 KB"; return }
        if card.value.provider == "ChatGPT" {
            guard !desktopReplyInProgress else { feedback[id] = "Another desktop reply is in progress"; return }
            // SessionJump has already validated the private URL against this tile's UUID.
            guard let target = jump?.web, let desktop = DesktopChatReply(target: target) else {
                feedback[id] = DesktopChatReply.Outcome.unavailable.message
                return
            }
            desktopReplyInProgress = true
            defer { desktopReplyInProgress = false }
            let outcome = await desktop.submit(draft, title: card.value.nativeChatTitle)
            if outcome == .submitted, drafts[id] == draft { drafts[id] = nil }
            if outcome == .unconfirmed { checkBeforeRetry.insert(id) }
            feedback[id] = outcome.message
            return
        }
        let outcome = await Self.send(draft, to: id.sessionID)
        switch outcome {
        case "sent":
            if drafts[id] == draft { drafts[id] = nil }
            feedback[id] = "Sent"
        case "uncertain":
            checkBeforeRetry.insert(id)
            feedback[id] = "Delivery unconfirmed · check the session"
        case "openSession":
            checkBeforeRetry.insert(id)
            feedback[id] = "Open the session to continue"
        default:
            feedback[id] = "Couldn’t send · draft kept"
        }
    }

    @MainActor func copyAndOpen(_ card: Card, jump: SessionJump?) async {
        let id = card.id
        guard let draft = drafts[id], let jump else { feedback[id] = "Session link unavailable"; return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(draft, forType: .string) else { feedback[id] = "Couldn’t copy draft"; return }
        var opened = await jump.open()
        if !opened && card.value.provider == "ChatGPT" { opened = await jump.open(browserOnly: true) }
        feedback[id] = opened ? "Draft copied · paste in the conversation" : "Draft copied · couldn’t open the session"
    }

    func edit(_ text: String, for id: Identity) {
        drafts[id] = text
        feedback[id] = nil
        checkBeforeRetry.remove(id)
    }

    private static func send(_ text: String, to key: String) async -> String {
        guard let script = Bundle.main.url(forResource: "monitor", withExtension: "py") else { return "rejected" }
        return await Task.detached {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-S", script.path, "--reply", key]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "rejected" }
            do {
                try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                return "uncertain"
            }
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let result = String(data: response, encoding: .utf8) else { return "uncertain" }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

struct TileReply: View {
    let card: Card
    let jump: SessionJump?
    @ObservedObject var replies: TileReplies

    private var handoff: Bool {
        TileReplies.usesHandoff(card, needsReview: replies.checkBeforeRetry.contains(card.id))
    }

    var body: some View {
        let id = card.id
        let text = replies.drafts[id] ?? ""
        let busy = replies.busy.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                TextField(card.origin == .fixture ? "Try a demo reply" : "Reply to this session", text: Binding(
                    get: { replies.drafts[id] ?? "" }, set: { replies.edit($0, for: id) }))
                    .textFieldStyle(.plain).disabled(busy)
                    .accessibilityLabel("Reply to " + card.value.title)
                    .onSubmit { Task { await replies.submit(card, jump: jump) } }
                Button { Task { await replies.submit(card, jump: jump) } } label: {
                    if busy { ProgressView().controlSize(.mini) }
                    else if handoff { Text("Copy & open").font(.caption2.bold()) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(handoff ? "Copy this draft and open its conversation" : "Send to this session")
                    .accessibilityLabel(handoff ? "Copy draft and open conversation" : "Send reply")
                    .contextMenu {
                        if !handoff && card.value.provider == "ChatGPT" && card.origin == .adapter {
                            Button("Copy & open") { Task { await replies.copyAndOpen(card, jump: jump) } }
                        }
                    }
            }.padding(7).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if let feedback = replies.feedback[id] { Text(feedback).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
