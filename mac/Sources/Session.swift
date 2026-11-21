import Foundation
import Darwin

enum SessionState: String, Codable {
    case running, needsInput, ready, unavailable
}

struct RequestOption: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    var description: String?
}

struct RequestQuestion: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    let options: [RequestOption]
    var allowsOther: Bool?
    var isSecret: Bool?
}

struct PendingRequest: Codable, Equatable {
    let id: String
    let action: String
    let reason: String
    let expiresAt: Date
    var route: String?
    var kind: String?
    var questions: [RequestQuestion]?

    var hasSelectableQuestions: Bool {
        guard let questions, !id.isEmpty, ["approval", "question"].contains(kind),
              !questions.isEmpty, Set(questions.map(\.id)).count == questions.count else { return false }
        return questions.allSatisfy { question in
            !question.id.isEmpty && !question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            question.isSecret != true && (!question.options.isEmpty || question.allowsOther == true) &&
            (kind != "approval" || question.allowsOther != true) &&
            Set(question.options.map(\.id)).count == question.options.count &&
            question.options.allSatisfy { !$0.id.isEmpty && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    func accepts(_ answers: [String: String]) -> Bool {
        guard hasSelectableQuestions, let questions, questions.count == answers.count else { return false }
        return questions.allSatisfy { question in
            guard let answer = answers[question.id] else { return false }
            return question.options.contains { $0.id == answer } ||
                (question.allowsOther == true && answer.utf8.count <= 8192 &&
                 !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct SessionDetails: Codable, Equatable {
    let model: String?
    let effort: String?
}

struct Snapshot: Codable, Equatable {
    let provider: String
    let sessionID: String
    var title: String
    var sentence: String
    var state: SessionState
    var updatedAt: Date
    var sessionURL: URL?
    var resultURL: URL?
    var nativeChatTitle: String?
    var desktopChat: Bool?
    var details: SessionDetails?
    var request: PendingRequest?
}

enum Origin: String, Codable { case adapter, fixture }

struct Identity: Hashable, Codable {
    let origin: Origin
    let provider: String
    let sessionID: String
}

struct Card: Identifiable, Equatable {
    var value: Snapshot
    let origin: Origin
    var source: URL?
    var quietChat = false
    var connected: Bool { value.state != .unavailable }
    var id: Identity { Identity(origin: origin, provider: value.provider, sessionID: value.sessionID) }
}

struct Saved: Codable {
    var pins: [Identity] = []
    var webLinks: [String: URL]?
    var watches: [Identity]? = []
    var lastKnown: [Snapshot] = []
}

struct Decision: Codable {
    let provider: String
    let sessionID: String
    let requestID: String
    let decision: String
    var answers: [String: String]?
}

enum Format {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let box = try decoder.singleValueContainer()
            let text = try box.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "Expected ISO 8601 date")
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func chatLink(_ text: String) -> (String, URL)? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "chatgpt.com",
              parts.port == nil, parts.user == nil, parts.password == nil else { return nil }
        let path = parts.path.split(separator: "/")
        guard (path.count == 2 || (path.count == 4 && path[0] == "g")),
              path[path.count - 2] == "c", let tail = path.last,
              let uuid = UUID(uuidString: String(tail)) else { return nil }
        let id = uuid.uuidString.lowercased()
        return (id, URL(string: "https://chatgpt.com/c/" + id)!)
    }

    static func resultViewer(_ url: URL) -> URL? {
        var info = stat()
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o111) == 0 else { return nil }
        switch url.pathExtension.lowercased() {
        case "md", "txt", "csv": return URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        case "pdf", "png", "jpg", "jpeg": return URL(fileURLWithPath: "/System/Applications/Preview.app")
        default: return nil
        }
    }

    static func webResult(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}

struct TileLayout {
    static let gap: CGFloat = 14
    static let inset: CGFloat = 16
    static let minimum: CGFloat = 244
    static let maximum: CGFloat = 300
    let available: CGFloat
    var capacity: Int { max(1, Int((available - 2 * Self.inset + Self.gap) / (Self.minimum + Self.gap))) }
    func tileWidth(for count: Int) -> CGFloat {
        let visible = CGFloat(min(capacity, max(1, count)))
        return max(1, min(Self.maximum, floor((available - 2 * Self.inset - (visible - 1) * Self.gap) / visible)))
    }
    func rowWidth(for count: Int) -> CGFloat {
        let visible = CGFloat(min(capacity, max(1, count)))
        return min(available, 2 * Self.inset + visible * tileWidth(for: count) + (visible - 1) * Self.gap)
    }
}

struct LibraryItem: Codable, Identifiable {
    let provider: String
    let sessionID: String
    let title: String
    let updated: Double
    var state: SessionState?
    var work: Bool?
    var desktopChat: Bool?
    var activityText: String?
    var parentID: String?
    var branchKind: String?
    var id: Identity { Identity(origin: .adapter, provider: provider, sessionID: sessionID) }
}
