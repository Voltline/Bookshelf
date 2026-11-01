import Foundation

struct ReadingActivityState: Equatable {
    var visible = false
    var ready = false
    var foreground = false
    var overlay = false
    var speaking = false
}

/// Wall time labels the day; monotonic time measures elapsed time. Long gaps
/// are deliberately not backfilled, since the process may have been suspended.
struct ReadingActivityClock {
    private var state = ReadingActivityState()
    private var previousDate: Date?
    private var previousUptime: Double?
    private var lastInteraction: Double?

    mutating func sample(state next: ReadingActivityState, interaction: Bool, now: Date, uptime: Double) -> [ReadingActivityInterval] {
        defer {
            state = next; previousDate = now; previousUptime = uptime
            if interaction { lastInteraction = uptime }
        }
        guard let previousDate, let previousUptime, uptime.isFinite else { return [] }
        let elapsed = uptime - previousUptime
        guard elapsed > 0, elapsed <= 30, state.visible, state.ready else { return [] }
        let kind: ReadingActivityKind
        var seconds = elapsed
        if state.speaking { kind = .listening }
        else {
            guard state.foreground, !state.overlay, let lastInteraction else { return [] }
            seconds = min(elapsed, max(0, lastInteraction + 300 - previousUptime))
            guard seconds > 0 else { return [] }
            kind = .reading
        }
        let wallElapsed = now.timeIntervalSince(previousDate)
        let start = abs(wallElapsed - elapsed) < 2 ? previousDate : now.addingTimeInterval(-elapsed)
        return [.init(start: start, end: start.addingTimeInterval(seconds), kind: kind)]
    }
}

@MainActor
final class ReadingActivitySession {
    private let bookID: UUID
    private let store: ReadingActivityStore
    private let id = UUID()
    private var clock = ReadingActivityClock()
    private var state = ReadingActivityState()
    private var timer: Task<Void, Never>?
    private var started = false
    private var lastPulse = 0.0

    init(bookID: UUID, store: ReadingActivityStore) { self.bookID = bookID; self.store = store }

    func update(_ next: ReadingActivityState, interaction: Bool = false, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if next.visible, !started {
            started = true
            store.activateSession(id)
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let session = self else { return }
                    session.pulse()
                }
            }
        }
        guard started else { return }
        if next.visible, next.foreground, interaction, !store.isActiveSession(id) {
            // Another window may have owned the recorder. Never backfill its
            // interval when this reader becomes active again.
            clock = ReadingActivityClock()
            store.activateSession(id)
        }
        for interval in clock.sample(state: next, interaction: interaction, now: now, uptime: uptime) {
            store.record(interval, bookID: bookID, sessionID: id)
        }
        state = next; lastPulse = uptime
        if !next.visible {
            timer?.cancel(); timer = nil; started = false
            clock = ReadingActivityClock()
            store.endSession(id)
        }
    }

    /// Frequent TTS callbacks keep background audio accountable even when a
    /// UI timer is delayed, without publishing a change for every spoken word.
    func pulse(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard started, uptime - lastPulse >= 4.5 else { return }
        update(state, now: now, uptime: uptime)
    }
}
