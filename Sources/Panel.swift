import SwiftUI
import AppKit

private let accent = Color(red: 0.66, green: 0.86, blue: 0.76)
extension Card {
    var label: String {
        if origin == .fixture { return "Demo" }
        if value.provider == "ChatGPT" && value.state == .unavailable && value.sessionURL != nil { return "Saved link" }
        return value.state == .unavailable ? "Offline" : "Connected"
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
    @State private var source = "ChatGPT"
    @State private var link = ""
    @State private var title = ""
    @State private var webLink = ""
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
                        Text("\(store.pinned.count)/5").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
                        ScrollView { manage.padding(16) }
                            .background(.black.opacity(0.88),in: RoundedRectangle(cornerRadius: 16))
                    } else if store.pinned.isEmpty {
                        Button("Pin a session") { panel.managing = true }
                            .padding(10).background(.black.opacity(0.82),in: Capsule())
                    } else {
                        let count = CGFloat(store.pinned.count)
                        let gap: CGFloat = 16
                        let width = max(216,(panel.displayWidth - 32 - (count - 1) * gap) / count)
                        ScrollView([.horizontal,.vertical],showsIndicators: false) {
                            HStack(alignment: .top,spacing: gap) {
                                ForEach(Array(store.pinned.enumerated()), id: \.element.id) { index, card in
                                    SessionTile(card: card, store: store, panel: panel, index: index, width: width)
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
        }.buttonStyle(.plain).foregroundStyle(Color.white)
            .environment(\.colorScheme,.dark)
    }

    private var manage: some View {
        VStack(alignment: .leading,spacing: 10) {
            Picker("Add session",selection: $source) {
                Text("ChatGPT").tag("ChatGPT")
                Text("Codex").tag("Codex")
            }.pickerStyle(.segmented)
            TextField(source == "ChatGPT" ? "Private conversation URL" : "Thread ID or codex://threads/ link", text: $link).textFieldStyle(.roundedBorder)
            if source == "ChatGPT" { TextField("Session title",text: $title).textFieldStyle(.roundedBorder) }
            if source == "Codex" {
                TextField("Web link for this thread (optional)",text: $webLink).textFieldStyle(.roundedBorder)
            }
            Button(source == "ChatGPT" ? "Pin conversation link" : "Watch Codex thread") {
                let success = source == "ChatGPT" ? store.addChat(link,title: title) : store.watchCodex(link,webLink: webLink)
                if success { link = ""; title = ""; webLink = ""; panel.managing = false }
            }.buttonStyle(.bordered).disabled(link.isEmpty)
            Divider()
            ForEach(store.catalog) { card in
                let pinned = store.saved.pins.contains(card.id)
                HStack {
                    VStack(alignment: .leading) {
                        Text(card.value.title).font(.callout.weight(.medium))
                        Text(card.value.provider + " · " + card.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(pinned ? "Unpin" : "Pin") { if pinned { store.unpin(card.id) } else { store.pin(card.id) } }
                        .buttonStyle(.bordered).disabled(!pinned && store.saved.pins.count >= 5)
                }
            }
            Divider()
            Button("Replay demo events") { store.resetDemo(); panel.managing = false }.foregroundStyle(accent)
        }
    }
}

private struct SessionTile: View {
    let card: Card
    let store: Store
    let panel: PanelState
    let index: Int
    let width: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var light = UnitPoint(x: 0.2, y: 0)
    @State private var receipt: String?
    @State private var hovered = false

    private var stateName: String {
        switch card.value.state {
        case .running: return "Working"
        case .needsInput: return "Needs input"
        case .ready: return "Ready"
        case .unavailable: return card.label == "Saved link" ? "Saved link" : "Offline"
        }
    }

    @State private var opening = false
    private var jump: SessionJump? { SessionJump(card: card,pairedWebLink: store.saved.webLinks?[card.value.sessionID]) }

    private func navigate(_ route: SessionJump,browserOnly: Bool = false) {
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            defer { opening = false }
            if await route.open(browserOnly: browserOnly) { panel.expanded = false }
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
                else if card.value.state != .unavailable { Text("· Live").foregroundStyle(accent) }
                Spacer(minLength: 2)
                ActivityMark(state: card.value.state,tint: card.tint)
                Text(stateName).foregroundStyle(card.tint)
            }.font(.system(size: 10.5,weight: .medium))
            VStack(alignment: .leading,spacing: 5) {
                Text(card.value.title).font(.system(size: 17,weight: .semibold)).lineLimit(2)
                TypedStatus(sentence: card.value.sentence, id: card.id, panel: panel)
            }
            if let request = card.value.request {
                Divider()
                VStack(alignment: .leading,spacing: 3) {
                    Text(request.action).font(.system(size: 12,weight: .semibold))
                    Text(request.reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
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
                    if let url = card.value.resultURL, Format.canOpen(url,result: true,provider: card.value.provider) {
                        Button {
                            if !NSWorkspace.shared.open(url) { store.notice = "macOS could not open this destination." }
                        } label: { Label("Open result",systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(accent) }
                    }
                }
            }
            if let jump {
                Button { navigate(jump) } label: {
                    Label("Jump in",systemImage: "arrow.up.forward.app").font(.caption.weight(.semibold))
                        .padding(.horizontal,9).padding(.vertical,5).background(.white.opacity(0.12),in: Capsule())
                }.disabled(opening).help("Return to " + card.value.title)
                    .accessibilityLabel("Jump in to " + card.value.title)
                    .contextMenu {
                        if jump.web != nil { Button("Open in browser") { navigate(jump,browserOnly: true) } }
                    }
            }
        }.padding(14).frame(maxWidth: .infinity,alignment: .leading)
            .background {
                shape.fill(Color(red: 0.042,green: 0.054,blue: 0.068).opacity(solid ? 1 : 0.82))
                shape.fill(RadialGradient(colors: [card.tint.opacity(hovered ? 0.24 : 0.14),.clear],
                                          center: light,startRadius: 0,endRadius: max(160,width * 0.72)))
            }
            .overlay { shape.strokeBorder(.white.opacity(hovered ? 0.38 : 0.20),lineWidth: 1) }
            .shadow(color: .black.opacity(0.27),radius: 5,y: 4)
             .scaleEffect(reduceMotion || entered ? 1 : 0.88,anchor: .top)
            .offset(x: reduceMotion || entered ? 0 : (panel.displayWidth / 2 - (16 + (width + 16) * CGFloat(index) + width / 2)) * 0.12,
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
                receipt = card.origin == .fixture ? (allow ? "Approved" : "Denied") : "Decision sent"
            }
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
    @State private var visible = ""
    @State private var typing = false

    var body: some View {
        // Reserve the final sentence's space so typing never shifts the decision buttons.
        Text(sentence).hidden().accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                Text("\(reduceMotion ? sentence : visible)\(Text(typing && !reduceMotion ? "▏" : "").foregroundColor(accent))").foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13,weight: .medium,design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(false)
            .accessibilityLabel(sentence)
            .task(id: sentence) {
                if reduceMotion || panel.shownSentences[id] == sentence {
                    visible = sentence
                    typing = false
                    return
                }
                panel.shownSentences[id] = sentence
                visible = ""
                typing = true
                let characters = Array(sentence)
                let batch = max(1,(characters.count + 49) / 50)
                var end = 0
                while end < characters.count {
                    guard !Task.isCancelled else { return }
                    let next = min(characters.count,end + batch)
                    visible.append(contentsOf: characters[end..<next])
                    end = next
                    if end < characters.count {
                        do { try await Task.sleep(nanoseconds: 20_000_000) }
                        catch { return }
                    }
                }
                typing = false
            }
    }
}
