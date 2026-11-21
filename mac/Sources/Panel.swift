import SwiftUI
import ApplicationServices
import AppKit

private let accent = Color(red: 0.66, green: 0.86, blue: 0.76)
extension Card {
    var label: String {
        if origin == .fixture { return "Demo" }
        if value.provider == "ChatGPT" && value.state == .unavailable && value.sessionURL != nil {
            return value.desktopChat == true ? "Offline" : "Saved link"
        }
        return value.state == .unavailable ? "Offline" : "Connected"
    }
    var stateName: String {
        switch value.state {
        case .running: return "Working"
        case .needsInput: return "Needs input"
        case .ready: return quietChat ? "Watching" : "Ready"
        case .unavailable: return label
        }
    }

    var tint: Color {
        switch value.state {
        case .running: return Color.cyan
        case .needsInput: return Color.orange
        case .ready: return accent
        case .unavailable: return Color.gray
        }
    }
}

final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var managing = false
    @Published var displayWidth: CGFloat = 1024
    @Published var rowHeight: CGFloat = 240
    let replies = TileReplies()
    var shownSentences: [Identity: String] = [:]
}

private struct TileRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}

struct PanelView: View {
    private static let owl = Bundle.main.url(forResource: "watching-owl",withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    @ObservedObject var store: Store
    @ObservedObject var panel: PanelState
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var library = SessionLibrary()
    private var branchParents: [String] {
        guard panel.expanded && !panel.managing else { return [] }
        return store.saved.pins.filter { $0.origin == .adapter && $0.provider == "Codex" }.map(\.sessionID)
    }
    var body: some View {
        Group {
            if !panel.expanded {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.split.3x1").foregroundStyle(accent)
                        Spacer()
                        ForEach(store.pinned) { card in Circle().fill(card.tint).frame(width: 4,height: 4) }
                        if store.pinned.isEmpty { Image(systemName: "plus") }
                    }.padding(.horizontal,12).frame(maxWidth: .infinity,maxHeight: .infinity).contentShape(Rectangle())
                }
                .background(.black,in: RoundedRectangle(cornerRadius: 12))
                .help("Open pinned sessions").accessibilityLabel("Open pinned sessions")
            } else {
                VStack(spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.split.3x1").foregroundStyle(accent)
                        Text(panel.managing ? "Manage sessions" : "Pinned sessions").font(.system(size: 12,weight: .semibold))
                        Text("\(store.pinned.count)/\(store.pinLimit)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Divider().frame(height: 12)
                        Button { panel.managing.toggle(); store.notice = nil } label: {
                            Image(systemName: panel.managing ? "checkmark" : "slider.horizontal.3")
                        }.help(panel.managing ? "Done" : "Manage sessions")
                        Button(action: toggle) { Image(systemName: "chevron.up") }.help("Collapse")
                    }.padding(.horizontal,13).frame(height: 28)
                        .background(.black.opacity(0.83),in: Capsule())
                    if let message = store.notice {
                        HStack {
                            Text(message).font(.caption)
                            Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        }.padding(8).background(.black.opacity(0.88),in: Capsule())
                    }
                    if panel.managing {
                        SessionSettings(store: store, library: library)
                    } else if store.pinned.isEmpty {
                        Button("Pin a session") { panel.managing = true }
                            .padding(10).background(.black.opacity(0.82),in: Capsule())
                    } else {
                        let gap = TileLayout.gap
                        let width = TileLayout(available: panel.displayWidth).tileWidth(for: store.pinned.count)
                        ScrollView([.horizontal,.vertical],showsIndicators: false) {
                            HStack(alignment: .top,spacing: gap) {
                                ForEach(Array(store.pinned.enumerated()), id: \.element.id) { index, card in
                                    SessionTile(card: card, store: store, panel: panel, index: index, width: width, branches: card.origin == .adapter && card.value.provider == "Codex" ? library.branches[card.value.sessionID] ?? [] : [])
                                        .frame(width: width)
                                }
                            }.padding(.top,17)
                            .overlay(alignment: .topLeading) {
                                if let owl = Self.owl, let watched = store.watchedSession, let index = store.pinned.firstIndex(where: { $0.id == watched }) {
                                    Image(nsImage: owl)
                                        .resizable().scaledToFill().frame(width: 42,height: 42)
                                        .frame(width: 32,height: 28).clipShape(Capsule())
                                        .overlay { Capsule().strokeBorder(.white.opacity(0.5),lineWidth: 1) }
                                        .shadow(color: .black.opacity(0.3),radius: 2,y: 1)
                                        .accessibilityLabel("Watching " + store.pinned[index].value.title)
                                        .allowsHitTesting(false)
                                        .offset(x: CGFloat(index) * (width + gap) + width - 58)
                                        .animation(reduceMotion ? nil : .spring(response: 0.48,dampingFraction: 0.82),value: index)
                                }
                            }.padding(.horizontal,16).padding(.bottom,16)
                            .background { GeometryReader { bounds in
                                Color.clear.preference(key: TileRowHeight.self,value: bounds.size.height)
                            } }
                        }.onPreferenceChange(TileRowHeight.self) { height in
                            if height > 0 && abs(panel.rowHeight - height) >= 1 { panel.rowHeight = ceil(height) }
                        }
                    }
                }.padding(.top,3).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top)
            }
        }.task(id: panel.managing && panel.expanded || store.saved.pins.contains { $0.provider == "ChatGPT" && $0.origin == .adapter }) {
            guard panel.managing && panel.expanded || store.saved.pins.contains(where: { $0.provider == "ChatGPT" && $0.origin == .adapter }) else { return }
            while !Task.isCancelled {
                await library.refreshChats(store: store)
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }.task(id: branchParents) {
            let parents = branchParents
            var poll = 0
            repeat {
                await library.refreshBranches(for: parents, includeForks: poll.isMultiple(of: 12))
                poll += 1
                if parents.isEmpty || Task.isCancelled { return }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            } while !Task.isCancelled
        }.buttonStyle(.plain).foregroundStyle(Color.white)
            .environment(\.colorScheme,.dark)
    }

}

private struct SessionTile: View {
    let card: Card
    let store: Store
    let panel: PanelState
    let index: Int
    let width: CGFloat
    let branches: [LibraryItem]
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var light = UnitPoint(x: 0.2, y: 0)
    @State private var receipt: String?
    @State private var hovered = false


    @State private var usage: [UsageWindow]?
    @State private var showingDetails = false
    @State private var opening = false
    private var jump: SessionJump? { SessionJump(card: card,pairedWebLink: store.saved.webLinks?[card.value.sessionID]) }

    private func navigate(_ route: SessionJump,browserOnly: Bool = false) {
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            defer { opening = false }
            if await route.open(browserOnly: browserOnly) { panel.expanded = false }
            else if card.value.provider == "ChatGPT" && !browserOnly {
                store.notice = AXIsProcessTrusted() ? "This chat isn’t visible in ChatGPT. Use Open in browser on the tile." : "Allow watchnotch in System Settings → Privacy & Security → Accessibility, then try Jump in again."
            }
            else { store.notice = "Could not open " + card.value.title + (route.web == nil ? ". Add its web link in Manage sessions if one exists." : ". Check the session link and try again.") }
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17,style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: card.value.provider == "Codex" ? "terminal" : "bubble.left")
                Text(card.value.provider).fontWeight(.semibold)
                if card.origin == .fixture { Text("· Demo").foregroundStyle(.white.opacity(0.65)) }
                else if card.connected { Text("· Live").foregroundStyle(accent) }
                Spacer(minLength: 2)
                Button {
                    usage = nil
                    showingDetails.toggle()
                } label: {
                    Image(systemName: "info.circle").frame(width: 22, height: 22)
                }
                .help("Model, reasoning effort and Codex account usage")
                .accessibilityLabel("Session details for " + card.value.title)
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(card.value.title).font(.headline).lineLimit(2)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                            GridRow { Text("Model"); Text(card.value.details?.model ?? "Not reported") }
                            GridRow { Text("Effort"); Text(card.value.details?.effort ?? "Not reported") }
                            if card.origin == .adapter && card.value.provider == "Codex" {
                                Text("Codex account usage").font(.headline)
                                if let usage {
                                    if usage.isEmpty { Text("Account usage unavailable") }
                                    ForEach(usage.indices, id: \.self) { i in
                                        GridRow { Text(usage[i].label); Text("\(usage[i].usedPercent)% used") }
                                    }
                                } else {
                                    Text("Reading account limits…")
                                }
                            }
                        }.font(.callout).textSelection(.enabled)
                    }.padding(16).frame(maxWidth: 340, alignment: .leading)
                    .task {
                        guard card.origin == .adapter && card.value.provider == "Codex" else { return }
                        let windows = (try? await SessionLibrary.accountUsage()) ?? []
                        if !Task.isCancelled { usage = windows }
                    }
                }
                ActivityMark(state: card.value.state,tint: card.tint)
                Text(card.stateName).foregroundStyle(card.tint)
            }.font(.system(size: 10.5,weight: .medium))
            VStack(alignment: .leading,spacing: 5) {
                Text(card.value.title).font(.system(size: 17,weight: .semibold)).lineLimit(2)
                if card.value.request == nil {
                    if card.value.state == .needsInput {
                        Text(card.value.sentence).font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TypedStatus(sentence: card.value.sentence, id: card.id, panel: panel)
                    }
                }
            }
            if let request = card.value.request {
                Divider()
                if request.hasSelectableQuestions, let questions = request.questions {
                    RequestChoices(request: request, questions: questions, sessionTitle: card.value.title) { answers in
                        if await store.answer(card.id, requestID: request.id, answers: answers) {
                            let response = request.kind == "approval" ? "Decision" : "Answer"
                            let delivered = card.origin == .fixture || request.route == "chatDesktop"
                            receipt = response + (delivered ? " sent" : " queued")
                        }
                    }.id(request.id)
                } else if request.kind == nil && request.questions == nil {
                    VStack(alignment: .leading,spacing: 3) {
                        Text(request.action).font(.system(size: 13,weight: .semibold))
                        Text(request.reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    }.fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { resolve(request, allow: true) } label: {
                            Label("Approve once",systemImage: "checkmark").padding(.horizontal,9).padding(.vertical,5)
                                .foregroundStyle(Color.black).background(accent,in: Capsule())
                        }.accessibilityLabel("Approve once for " + card.value.title)
                        Button { resolve(request, allow: false) } label: {
                            Text("Deny").padding(.horizontal,10).padding(.vertical,5)
                                .background(.white.opacity(0.13),in: Capsule())
                        }.accessibilityLabel("Deny for " + card.value.title)
                    }.font(.system(size: 12,weight: .semibold)).buttonStyle(DecisionButtonStyle())
                }
            } else {
                HStack {
                    if let receipt {
                        Label(receipt,systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(accent)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Text(card.value.updatedAt,style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.66))
                    }
                    Spacer()
                    if let url = card.value.resultURL, Format.resultViewer(url) != nil || Format.webResult(url) {
                        Button {
                            Task { @MainActor in
                                if !(await SessionJump.openResult(url)) { store.notice = "macOS could not open this destination." }
                            }
                        } label: { Label("Open result",systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(accent) }
                    }
                }
            }
            if let jump {
                let jumpLabel = card.value.state == .needsInput && card.value.request == nil ? "Open session" : "Jump in"
                HStack {
                    Button { navigate(jump) } label: {
                        Label(jumpLabel, systemImage: "arrow.up.forward.app").font(.caption.weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.12), in: Capsule())
                    }.disabled(opening).help("Return to " + card.value.title)
                        .accessibilityLabel(jumpLabel + ", " + card.value.title)
                        .contextMenu {
                            if jump.web != nil { Button("Open in browser") { navigate(jump, browserOnly: true) } }
                        }
                    if card.value.provider == "ChatGPT" {
                        Button { navigate(jump, browserOnly: true) } label: { Image(systemName: "globe") }
                            .help("Open in browser").accessibilityLabel("Open in browser")
                    }
                }
            }
            if !branches.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 6) {
                        ForEach(branches) { branch in
                            let value = Snapshot(provider: "Codex", sessionID: branch.sessionID, title: branch.title, sentence: "", state: branch.state ?? .unavailable, updatedAt: Date(timeIntervalSince1970: branch.updated))
                            let child = Card(value: value, origin: .adapter)
                            Button {
                                if let route = SessionJump(card: child) { navigate(route) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(branch.branchKind == "Fork" && branch.state == .unavailable ? "Fork" : (branch.branchKind ?? "Branch") + " · " + child.stateName, systemImage: "arrow.triangle.branch")
                                        .font(.caption2).foregroundStyle(child.tint)
                                    Text(branch.title).font(.caption.weight(.semibold)).lineLimit(1)
                                }.padding(.horizontal, 8).padding(.vertical, 5)
                                    .frame(maxWidth: 152, alignment: .leading)
                                    .background(child.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            }.help("Open " + branch.title).accessibilityLabel("Open " + (branch.branchKind ?? "branch") + " " + branch.title)
                        }
                    }
                }
            }
            TileReply(card: card, jump: jump, replies: panel.replies)
        }.padding(14).frame(maxWidth: .infinity,alignment: .leading)
            .background {
                shape.fill(Color(red: 0.042,green: 0.054,blue: 0.068).opacity(solid ? 1 : 0.82))
                shape.fill(RadialGradient(colors: [card.tint.opacity(hovered ? 0.24 : 0.14),.clear],
                                          center: light,startRadius: 0,endRadius: max(160,width * 0.72)))
            }
            .overlay { shape.strokeBorder(.white.opacity(hovered ? 0.38 : 0.20),lineWidth: 1) }
            .shadow(color: .black.opacity(0.27),radius: 5,y: 4)
             .scaleEffect(reduceMotion || entered ? 1 : 0.88,anchor: .top)
            .offset(x: reduceMotion || entered ? 0 : (TileLayout(available: panel.displayWidth).rowWidth(for: store.pinned.count) / 2 - (16 + (width + TileLayout.gap) * CGFloat(index) + width / 2)) * 0.12,
                    y: reduceMotion ? 0 : (!entered ? -20 : (hovered ? -2 : 0)))
            .opacity(entered || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(response: 0.48,dampingFraction: 0.79).delay(Double(index) * 0.045)) { entered = true }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if !hovered { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovered = true } }
                    if !reduceMotion { light = UnitPoint(x: min(1,max(0,point.x / width)),y: min(1,max(0,point.y / 190))) }
                case .ended:
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        hovered = false
                        light = UnitPoint(x: 0.2,y: 0)
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.42,dampingFraction: 0.84),value: card.value.request?.id)
            .task(id: receipt) {
                guard receipt != nil else { return }
                do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { receipt = nil }
            }
    }
    private func resolve(_ request: PendingRequest, allow: Bool) {
        if store.decide(card.id,requestID: request.id,allow: allow) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.33,dampingFraction: 0.72)) {
                receipt = card.origin == .fixture ? (allow ? "Approved" : "Denied") : "Decision queued"
            }
        }
    }
}

private struct RequestChoices: View {
    let request: PendingRequest
    let questions: [RequestQuestion]
    let sessionTitle: String
    let onSubmit: @MainActor ([String: String]) async -> Void

    @State private var answers: [String: String] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var submitting = false

    private var complete: Bool { request.accepts(answers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if request.kind == "approval", !request.action.isEmpty, !questions.contains(where: { $0.prompt == request.action }) {
                Text(request.action).font(.system(size: 13, weight: .semibold))
            }
            if !request.reason.isEmpty, request.reason != request.action, !questions.contains(where: { $0.prompt == request.reason }) {
                Text(request.reason).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.prompt)
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(question.options, id: \.id) { option in
                        let selected = answers[question.id] == option.id && drafts[question.id] == nil
                        Button {
                            drafts.removeValue(forKey: question.id)
                            answers[question.id] = option.id
                            if questions.count == 1 { send() }
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 12, weight: .semibold))
                                    if let detail = option.description, !detail.isEmpty {
                                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 2)
                                Image(systemName: selected ? "checkmark.circle.fill" : (questions.count > 1 ? "circle" : "chevron.right"))
                                    .font(.caption2).foregroundStyle(selected ? accent : .secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? accent.opacity(0.18) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }.accessibilityHint(questions.count == 1 ? "Send this choice to " + sessionTitle : "Select for " + question.prompt)
                         .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    if question.allowsOther == true {
                        customAnswer(for: question)
                    }
                }
            }
            if submitting {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Sending…").font(.caption) }
            } else if questions.count > 1 || questions.first.map({ drafts[$0.id] != nil || $0.options.isEmpty }) == true {
                Button(action: send) {
                    Label(questions.count > 1 ? "Send answers" : "Send answer", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(Color.black).background(accent, in: Capsule())
                }.disabled(!complete).opacity(complete ? 1 : 0.5)
            }
        }
        .disabled(submitting)
        .buttonStyle(DecisionButtonStyle())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func customAnswer(for question: RequestQuestion) -> some View {
        let text = Binding<String>(
            get: { drafts[question.id] ?? "" },
            set: { value in
                drafts[question.id] = value
                answers[question.id] = value
            })
        let placeholder = question.options.isEmpty ? "Your answer" : "Write another answer"
        return TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.callout).padding(7)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(placeholder + " for " + question.prompt)
            .onSubmit { if questions.count == 1 { send() } }
    }

    private func send() {
        guard !submitting, complete else { return }
        submitting = true
        let response = answers
        Task { @MainActor in
            await onSubmit(response)
            submitting = false
        }
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24,dampingFraction: 0.66),value: configuration.isPressed)
    }
}

private struct ActivityMark: View {
    let state: SessionState
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state == .running && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20)) { frame in
                    let phase = frame.date.timeIntervalSinceReferenceDate * 5
                    HStack(alignment: .center,spacing: 2) {
                        ForEach(0..<3) { index in
                            Capsule().fill(tint).frame(width: 2,height: 3 + 6 * abs(sin(phase + Double(index) * 1.1)))
                        }
                    }.frame(width: 10,height: 11)
                }
            } else {
                Image(systemName: state == .ready ? "checkmark.circle.fill" : (state == .needsInput ? "hand.raised.fill" : "circle.fill"))
                    .font(.system(size: 9)).foregroundStyle(tint)
            }
        }.accessibilityHidden(true)
    }
}

private struct TypedStatus: View {
    let sentence: String
    let id: Identity
    let panel: PanelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var script = StatusScript()
    @State private var sampleTime: TimeInterval = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        let displayed = script.current ?? sentence
        let progress = script.progress(at: sampleTime)
        Text(displayed)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .lineSpacing(2)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask {
                if script.current == nil && !reduceMotion && panel.shownSentences[id] != sentence {
                    Color.clear
                } else if script.phase == .revealing && !reduceMotion {
                    GeometryReader { bounds in
                        let height = max(1, bounds.size.height)
                        let feather = min(14, height)
                        let edge = progress * (height + feather)
                        LinearGradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: max(0, (edge - feather) / height)),
                            .init(color: .clear, location: min(1, edge / height)),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                } else {
                    Color.white
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { script.reveal(at: now) }
            .help(script.phase == .revealing ? "Click to read the full update now" : displayed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayed)
            .accessibilityAction(named: "Reveal full update") { script.reveal(at: now) }
            .onAppear {
                script.receive(sentence, at: now, animate: !reduceMotion && panel.shownSentences[id] != sentence)
            }
            .onChange(of: sentence) { update in
                script.receive(update, at: now, animate: !reduceMotion)
            }
            .onChange(of: reduceMotion) { reduced in
                if reduced { script.reveal(at: now) }
            }
            .onDisappear {
                panel.shownSentences[id] = script.current
                script = StatusScript()
            }
            .task(id: script.deadline) {
                guard let deadline = script.deadline else { return }
                while now < deadline {
                    let remaining = max(0, deadline - now)
                    let revealing = script.phase == .revealing
                    let delay = revealing ? min(1.0 / 30, remaining) : remaining
                    do { try await Task.sleep(nanoseconds: UInt64(ceil(delay * 1_000_000_000))) }
                    catch { return }
                    if revealing && !Task.isCancelled { sampleTime = now }
                }
                guard !Task.isCancelled, script.deadline == deadline else { return }
                script.advance(at: now, animate: !reduceMotion)
            }
    }
}
