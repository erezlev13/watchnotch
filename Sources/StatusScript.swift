import Foundation

/// One expanded tile owns one queue. Times are measured against monotonic system uptime.
struct StatusScript {
    enum Phase { case revealing, reading, shown }

    private(set) var current: String?
    private(set) var phase = Phase.shown
    private(set) var deadline: TimeInterval?
    private var startedAt: TimeInterval = 0
    private var pending: [String] = []

    mutating func receive(_ sentence: String, at now: TimeInterval, animate: Bool) {
        guard !sentence.isEmpty, sentence != (pending.last ?? current) else { return }
        if phase == .shown {
            present(sentence, at: now, animate: animate)
        } else {
            pending.append(sentence)
        }
    }

    private mutating func present(_ sentence: String, at now: TimeInterval, animate: Bool) {
        current = sentence
        startedAt = now
        phase = .revealing
        // Even a short, single-line sentence gets a deliberate entrance.
        deadline = now + min(6.0, max(1.35, Double(sentence.count) * 0.045))
        if !animate { reveal(at: now) }
    }

    mutating func reveal(at now: TimeInterval) {
        guard phase == .revealing, let current else { return }
        phase = .reading
        let words = current.split(whereSeparator: { $0.isWhitespace }).count
        // Give the last line time on screen before a queued sentence replaces it.
        deadline = now + max(1.6, Double(words) * 0.26)
    }

    mutating func advance(at now: TimeInterval, animate: Bool) {
        guard let deadline, now >= deadline else { return }
        switch phase {
        case .revealing:
            reveal(at: now)
        case .reading:
            if pending.isEmpty {
                phase = .shown
                self.deadline = nil
            } else {
                let next = pending.removeFirst()
                present(next, at: now, animate: animate)
            }
        case .shown:
            break
        }
    }

    func progress(at now: TimeInterval) -> Double {
        guard phase == .revealing, let deadline else { return 1 }
        return min(1, max(0, (now - startedAt) / (deadline - startedAt)))
    }
}
