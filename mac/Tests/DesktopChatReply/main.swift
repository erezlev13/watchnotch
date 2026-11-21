import Foundation

@MainActor
func testReplies() async {
    let draft = "Reply from tile"
    var text: String? = ""
    var presses = 0
    func send(_ press: () -> DesktopChatReply.Press) async -> DesktopChatReply.Outcome {
        await DesktopChatReply.deliver(draft, read: { text }, write: { text = draft; return true },
                                       press: { presses += 1; return press() }, wait: {})
    }
    let success = await send { text = ""; return .pressed }
    precondition(success == .submitted && presses == 1)

    text = "Draft in ChatGPT"
    let busy = await send { fatalError("Overwrote a different draft") }
    precondition(busy == .existingDraft && text == "Draft in ChatGPT")
    text = nil
    let wrongChat = await send { fatalError("Unverified destination") }
    precondition(wrongChat == .composerUnavailable)

    text = draft
    let ambiguous = await send { .uncertain }
    precondition(ambiguous == .unconfirmed && presses == 2)
    let unchanged = await send { .pressed }
    precondition(unchanged == .unconfirmed && presses == 3)
    let switched = await DesktopChatReply.deliver(draft, read: { text }, write: { true },
        press: { fatalError("Pressed after navigation") }, wait: { text = nil })
    precondition(switched == .composerUnavailable)

    let key = UUID().uuidString.lowercased()
    var value = Snapshot(provider: "ChatGPT", sessionID: key, title: "Desktop conversation", sentence: "Watching",
                         state: .ready, updatedAt: Date(), desktopChat: true)
    func handoff(_ needsReview: Bool = false) -> Bool {
        TileReplies.usesHandoff(Card(value: value, origin: .adapter), needsReview: needsReview)
    }
    precondition(!handoff() && handoff(true))
    value.desktopChat = nil
    precondition(handoff())
    value.desktopChat = true
    value.state = .unavailable
    precondition(handoff())
    print("PASS  Desktop reply routing, composer submission, draft preservation, destination changes and uncertain delivery")
}
await testReplies()
