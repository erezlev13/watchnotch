import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let mint = Color(red: 0.57, green: 0.92, blue: 0.77)
private let lilac = Color(red: 0.76, green: 0.70, blue: 0.98)

private struct LibraryPage: Decodable {
    let items: [LibraryItem]
    let next: String?
}

@MainActor
final class SessionLibrary: ObservableObject {
    private var readingDesktop = false
    @Published private(set) var desktopRunning = false
    @Published private(set) var desktopChats: [LibraryItem] = []
    @Published private(set) var local: [LibraryItem] = []
    @Published private(set) var activity: [Identity: SessionState] = [:]
    @Published private(set) var branches: [String: [LibraryItem]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var readingChats = false
    @Published var message: String?

    private static func read(_ resource: String, arguments: [String]) async throws -> LibraryPage {
        guard let script = Bundle.main.url(forResource: resource, withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-S", script.path] + arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
            return try JSONDecoder().decode(LibraryPage.self, from: data)
        }.value
    }

    func refreshChats(store: Store) async {
        guard !readingDesktop else { return }
        readingDesktop = true
        defer { readingDesktop = false }
        let launch = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").compactMap(\.launchDate).max()
        let args = ["--desktop"] + (launch.map { ["--launched", String($0.timeIntervalSince1970)] } ?? [])
        do {
            let page = try await Self.read("library",arguments: args)
            try Task.checkCancellation()
            desktopRunning = launch != nil
            desktopChats = page.items
            store.updateChatActivity(desktopChats, desktopRunning: desktopRunning)
        } catch is CancellationError {
        } catch {
            desktopRunning = false
            desktopChats = desktopChats.map { var row = $0; row.state = nil; row.activityText = nil; return row }
            store.updateChatActivity([], desktopRunning: false)
            message = "Couldn’t read the ChatGPT desktop catalog. Use Find on this Mac or import an export."
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var cursor: String?
        var cursors = Set<String>()
        var seen = Set<Identity>()
        var items: [LibraryItem] = []
        do {
            repeat {
                let page = try await Self.read("monitor", arguments: ["--list"] + (cursor.map { ["--cursor", $0] } ?? []))
                try Task.checkCancellation()
                items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
                cursor = page.next
            } while cursor.map({ cursors.insert($0).inserted }) == true
            local = items
            activity = Dictionary(uniqueKeysWithValues: items.compactMap { row in row.state.map { (row.id, $0) } })
        } catch is CancellationError {
        } catch {
            activity = [:]
            message = "Couldn’t read local Codex sessions. Start Codex and refresh, or add a conversation link."
        }

    }

    func updateActivity() async {
        guard !loading else { return }
        var current: [Identity: SessionState] = [:]
        var loadedRows: [LibraryItem] = []
        var cursor: String?
        var seen = Set<String>()
        do {
            repeat {
                let page = try await Self.read("monitor", arguments: ["--loaded"] + (cursor.map { ["--cursor", $0] } ?? []))
                try Task.checkCancellation()
                loadedRows.append(contentsOf: page.items)
                for item in page.items { current[item.id] = item.state }
                cursor = page.next
            } while cursor.map({ seen.insert($0).inserted }) == true
        } catch is CancellationError { return }
        catch { current = [:] }
        guard !Task.isCancelled, !loading else { return }
        let existing = Set(local.map(\.id))
        local.append(contentsOf: loadedRows.filter { !existing.contains($0.id) })
        activity = current
    }

    func refreshBranches(for parents: [String], includeForks: Bool) async {
        guard !parents.isEmpty else { branches = [:]; return }
        let options = includeForks ? [] : ["--active-agents-only"]
        let page = try? await Self.read("monitor", arguments: options + ["--branches"] + parents)
        guard !Task.isCancelled else { return }
        let savedForks = includeForks && page != nil ? [] : parents.flatMap { branches[$0] ?? [] }.filter { $0.branchKind == "Fork" }
        let rows = (page?.items ?? []) + savedForks
        branches = Dictionary(grouping: rows.filter { $0.parentID != nil }, by: { $0.parentID ?? "" })
    }

    func findChats(file: URL?, store: Store) async {
        guard !readingChats else { return }
        readingChats = true
        defer { readingChats = false }
        do {
            let page = try await Self.read("library", arguments: file.map { ["--import-file", $0.path] } ?? ["--browser"])
            try store.saveChatLibrary(page.items)
            if file != nil {
                message = "Imported \(page.items.count) ChatGPT conversations."
            } else {
                message = page.items.isEmpty ? "No accessible ChatGPT conversation links found in browser history. Import a ChatGPT export or add a link." : "Found \(page.items.count) ChatGPT conversations in browser history."
            }
        } catch {
            message = file == nil ? "Couldn’t read browser history. You can also import a ChatGPT export." : "Couldn’t import this file. Choose a ChatGPT export ZIP or a conversations JSON file."
        }
    }
}

struct SessionSettings: View {
    @ObservedObject var store: Store
    @ObservedObject var library: SessionLibrary
    @State private var query = ""
    @State private var section = "All"
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adding = false
    @State private var provider = "ChatGPT"
    @State private var link = ""
    @State private var detail = ""
    @Environment(\.accessibilityReduceTransparency) private var solid
    private static let owl = Bundle.main.url(forResource: "watching-owl", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    private var rows: [LibraryItem] {
        let catalog = store.catalog
        func item(_ card: Card) -> LibraryItem {
            LibraryItem(provider: card.value.provider, sessionID: card.value.sessionID, title: card.value.title, updated: card.value.updatedAt.timeIntervalSince1970, state: card.value.state)
        }
        let desktop = Dictionary(uniqueKeysWithValues: library.desktopChats.map { ($0.id, $0) })
        var items: [LibraryItem]
        switch section {
        case "Pinned": items = store.pinned.map(item)
        case "Demo": items = catalog.filter { $0.origin == .fixture }.map(item)
        default:
            var unique: [Identity: LibraryItem] = [:]
            for row in catalog.filter({ $0.origin == .adapter }).map(item) + store.importedChats + library.local + library.desktopChats {
                unique[row.id] = row
            }
            items = unique.values.filter { section == "All" || section == "Active" || $0.provider == section }.sorted { a, b in a.updated == b.updated ? a.title < b.title : a.updated > b.updated }
        }
        if section != "Demo" {
            items = items.map { item in
                guard identity(item).origin != .fixture else { return item }
                if var chat = desktop[item.id] {
                    chat.desktopChat = true
                    return chat
                }
                var row = item
                row.desktopChat = nil
                row.state = library.activity[item.id]
                return row
            }
        }
        if section == "Active" { items = items.filter { $0.state == .running || $0.state == .needsInput } }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (id, _) = Format.chatLink(term), ["All", "ChatGPT"].contains(section) {
            return [items.first { $0.provider == "ChatGPT" && $0.sessionID == id } ??
                LibraryItem(provider: "ChatGPT", sessionID: id, title: "ChatGPT conversation · " + String(id.prefix(8)), updated: 0)]
        }
        return term.isEmpty ? items : items.filter { ($0.work == true && "ChatGPT Work".localizedCaseInsensitiveContains(term)) || $0.title.localizedCaseInsensitiveContains(term) || $0.provider.localizedCaseInsensitiveContains(term) || $0.sessionID.localizedCaseInsensitiveContains(term) }
    }

    private var emptyMessage: String {
        if library.loading && section != "ChatGPT" { return "Loading sessions…" }
        if !query.isEmpty { return "No sessions match this search." }
        switch section {
        case "Active": return "No sessions currently report activity."
        case "All", "ChatGPT": return "Find conversations on this Mac or import a ChatGPT export below."
        default: return "No sessions here yet."
        }
    }

    private func identity(_ row: LibraryItem) -> Identity {
        if section == "Demo" || section == "Pinned",
           let fixture = store.catalog.first(where: { $0.origin == .fixture && $0.value.sessionID == row.sessionID && $0.value.provider == row.provider }) {
            return fixture.id
        }
        return row.id
    }

    private func sourceLabel(_ row: LibraryItem, origin: Origin) -> String {
        if origin == .fixture { return row.provider + " · Demo" }
        if row.provider == "Codex" { return "Codex · Local session" }
        if row.work == true { return "ChatGPT Work" }
        return row.desktopChat == true ? "ChatGPT Chat" : "ChatGPT · Conversation link"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let owl = Self.owl {
                    Image(nsImage: owl).resizable().scaledToFill().frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 15)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session library").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(library.desktopChats.count) desktop chats · \(store.saved.pins.count)/\(store.pinLimit) pinned").font(.caption).foregroundStyle(mint)
                }
                Spacer()
                Button { Task { await library.refreshChats(store: store); await library.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).background(.white.opacity(0.09), in: Circle())
                }.disabled(library.loading).help("Refresh local sessions").accessibilityLabel("Refresh local sessions")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(mint)
                TextField("Search sessions or paste a conversation link", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(10).background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(mint.opacity(0.26)) }
            HStack(spacing: 3) {
                ForEach(["All","Active","ChatGPT","Codex","Pinned","Demo"], id: \.self) { tab in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32,dampingFraction: 0.85)) { section = tab }
                    } label: {
                        Text(tab).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(tab == section ? .black : .white)
                            .background {
                                if section == tab { Capsule().fill(mint).matchedGeometryEffect(id: "selected",in: tabs) }
                            }
                    }
                }
                Spacer()
                if library.loading || library.readingChats { ProgressView().controlSize(.small).accessibilityLabel("Loading sessions") }
            }
            if let message = library.message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { library.message = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss message")
                }
            }
            let visibleRows = rows
            ScrollView {
                LazyVStack(spacing: 5) {
                    if visibleRows.isEmpty {
                        Text(emptyMessage)
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(visibleRows) { row in
                        let key = identity(row)
                        let pinned = store.saved.pins.contains(key)
                        let tint = row.provider == "Codex" ? mint : lilac
                        HStack(spacing: 10) {
                            Image(systemName: row.provider == "Codex" ? "terminal" : "bubble.left.and.bubble.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                                .frame(width: 32, height: 32).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.callout.weight(.medium)).lineLimit(1).help(row.title)
                                Text(sourceLabel(row, origin: key.origin)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let status = row.state, status != .unavailable {
                                let label = status == .needsInput ? "Needs input" : (status == .running ? "Active" : (row.provider == "ChatGPT" ? "New reply" : "Idle"))
                                let color = status == .needsInput ? Color.orange : (status == .running ? mint : .secondary)
                                Label(label, systemImage: status == .running ? "waveform" : (status == .needsInput ? "hand.raised.fill" : "pause.circle"))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(color)
                                    .padding(.horizontal, 6).padding(.vertical, 3).background(color.opacity(0.10), in: Capsule())
                            } else if row.desktopChat == true && library.desktopRunning {
                                Text("No activity reported").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Button {
                                if pinned { store.unpin(key) }
                                else if key.origin == .fixture || !["ChatGPT","Codex"].contains(row.provider) { store.pin(key) }
                                else if row.provider == "Codex" { _ = store.watchCodex(row.sessionID) }
                                else { _ = store.addChat("https://chatgpt.com/c/" + row.sessionID, title: row.title) }
                            } label: {
                                Image(systemName: pinned ? "pin.fill" : "pin").foregroundStyle(pinned ? mint : .secondary)
                                    .frame(width: 30, height: 30).background(.white.opacity(0.05), in: Circle())
                            }.help(pinned ? "Unpin session" : "Pin session").accessibilityLabel((pinned ? "Unpin " : "Pin ") + row.title)
                        }.padding(.vertical, 4).padding(.horizontal, 8)
                            .background(.white.opacity(pinned ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider()
            if adding {
                Picker("Provider", selection: $provider) { Text("ChatGPT").tag("ChatGPT"); Text("Codex").tag("Codex") }.pickerStyle(.segmented)
                TextField(provider == "Codex" ? "Thread ID or codex:// link" : "Private ChatGPT conversation URL", text: $link).textFieldStyle(.roundedBorder)
                TextField(provider == "Codex" ? "Web link (optional)" : "Title (optional)", text: $detail).textFieldStyle(.roundedBorder)
                Button("Pin session") {
                    let ok = provider == "Codex" ? store.watchCodex(link, webLink: detail) : store.addChat(link, title: detail)
                    if ok { link = ""; detail = ""; adding = false; section = "Pinned" }
                }.buttonStyle(.borderedProminent).tint(mint).disabled(link.isEmpty)
            }
            if section == "All" || section == "ChatGPT" {
                VStack(alignment: .leading,spacing: 7) {
                    Label("ChatGPT history",systemImage: "bubble.left.and.bubble.right").font(.callout.bold())
                    Text("Desktop chats appear automatically. For more, find visited chats or import your account export.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            section = "ChatGPT"
                            Task { await library.findChats(file: nil,store: store) }
                        } label: { Label("Find on this Mac",systemImage: "magnifyingglass").padding(6) }
                            .background(lilac.opacity(0.18),in: RoundedRectangle(cornerRadius: 7))
                        Button("Import export…") { chooseExport() }.buttonStyle(.bordered)
                        Spacer()
                        Link("Get an export ↗",destination: URL(string: "https://help.openai.com/en/articles/7260999")!)
                    }.font(.caption.weight(.semibold)).disabled(library.readingChats)
                }.padding(10).background(lilac.opacity(0.07),in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                if section == "Demo" { Button("Replay demo") { store.resetDemo() }.font(.caption) }
                Spacer()
                Button { adding.toggle() } label: { Label(adding ? "Close" : "Add link", systemImage: adding ? "xmark" : "link") }.foregroundStyle(mint)
            }.font(.callout)
        }.padding(17)
        .background {
            RoundedRectangle(cornerRadius: 21).fill(Color(red: 0.052, green: 0.069, blue: 0.092).opacity(solid ? 1 : 0.98))
            RoundedRectangle(cornerRadius: 21).fill(LinearGradient(colors: [mint.opacity(0.13), .clear, lilac.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.18)) }
        .task {
            await library.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                await library.updateActivity()
            }
        }
    }

    private func chooseExport() {
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [.json, .zip]
        dialog.prompt = "Import conversations"
        dialog.message = "Choose a ChatGPT export ZIP or conversations JSON. Only conversation titles, IDs and dates are saved."
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        section = "ChatGPT"
        Task { await library.findChats(file: url, store: store) }
    }
}
