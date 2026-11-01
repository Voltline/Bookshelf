#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

enum ReadingActivityRegressionChecks {
    static func run(directory: URL, source: URL) async throws -> [String] {
        let base = ISO8601DateFormatter().date(from: "2026-10-30T23:59:50+08:00")!
        let state = ReadingActivityState(visible: true, ready: true, foreground: true)
        var clock = ReadingActivityClock()
        var intervals: [ReadingActivityInterval] = []
        var current = state
        func sample(_ offset: Double, interaction: Bool = false) {
            intervals += clock.sample(state: current, interaction: interaction, now: base.addingTimeInterval(offset), uptime: 100 + offset)
        }
        sample(0, interaction: true)
        sample(5)
        current.speaking = true; sample(10)
        current.foreground = false; sample(15)
        current.speaking = false; sample(20)
        current.foreground = true; sample(25, interaction: true)
        current.overlay = true; sample(30)
        current.overlay = false; sample(35, interaction: true)
        current.visible = false; sample(40)
        sample(45)
        let reading = intervals.filter { $0.kind == .reading }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let listening = intervals.filter { $0.kind == .listening }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        try require(reading == 20 && listening == 10, "foreground / TTS / background / overlay / close accounting")
        var results = ["PASS: reader / listening modes are exclusive; background, overlays and closing stop manual time"]

        var idleClock = ReadingActivityClock()
        _ = idleClock.sample(state: state, interaction: true, now: base, uptime: 0)
        var idleTotal = 0.0
        for seconds in stride(from: 30.0, through: 330.0, by: 30) {
            idleTotal += idleClock.sample(state: state, interaction: false, now: base.addingTimeInterval(seconds), uptime: seconds).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }
        try require(idleTotal == 300, "idle cap")
        _ = idleClock.sample(state: state, interaction: true, now: base.addingTimeInterval(335), uptime: 335)
        let resumed = idleClock.sample(state: state, interaction: false, now: base.addingTimeInterval(340), uptime: 340)
        try require(resumed.first?.end.timeIntervalSince(resumed.first!.start) == 5, "interaction resumes idle clock")
        try require(idleClock.sample(state: state, interaction: false, now: base.addingTimeInterval(1000), uptime: 1000).isEmpty, "suspension is not backfilled")
        let skew = idleClock.sample(state: state, interaction: true, now: base.addingTimeInterval(2000), uptime: 1005)
        try require(skew.isEmpty, "idle remains idle across clock change")
        let shifted = idleClock.sample(state: state, interaction: false, now: base.addingTimeInterval(100), uptime: 1010)
        try require(shifted.first?.end.timeIntervalSince(shifted.first!.start) == 5, "wall clock cannot inflate elapsed time")
        results.append("PASS: five-minute idle cap resumes on interaction; suspended gaps and wall-clock jumps do not inflate totals")

        let root = directory.appendingPathComponent("ReadingActivity", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let activity = ReadingActivityStore(directory: root)
        let bookID = UUID(), otherID = UUID(), token = UUID()
        activity.activateSession(token)
        activity.record(.init(start: base, end: base.addingTimeInterval(20), kind: .reading), bookID: bookID, sessionID: token, calendar: calendar)
        try require(activity.totals(day: "2026-10-30").reading == 10 && activity.totals(day: "2026-10-31").reading == 10, "midnight split")
        activity.record(.init(start: base, end: base.addingTimeInterval(10), kind: .listening), bookID: otherID, sessionID: UUID(), calendar: calendar)
        try require(activity.totals().listening == 0, "inactive session guard")
        for day in ["2026-10-28T12:00:00+08:00", "2026-10-29T12:00:00+08:00", "2026-10-30T12:00:00+08:00"] {
            let date = ISO8601DateFormatter().date(from: day)!
            for id in [bookID, otherID] {
                activity.record(.init(start: date, end: date.addingTimeInterval(30), kind: .reading), bookID: id, sessionID: token, calendar: calendar)
            }
        }
        let today = base.addingTimeInterval(20)
        try require(activity.streak(now: today, calendar: calendar) == 3, "streak sums books and starts yesterday")
        activity.record(.init(start: today, end: today.addingTimeInterval(50), kind: .listening), bookID: bookID, sessionID: token, calendar: calendar)
        try require(activity.streak(now: today, calendar: calendar) == 4, "today extends streak")
        try require(activity.setGoal(minutes: 30) && !activity.setGoal(minutes: -1) && !activity.setGoal(minutes: 241), "goal validation")
        activity.endSession(token)
        let restored = ReadingActivityStore(directory: root)
        try require(restored.goalMinutes == 30 && restored.totals().total == activity.totals().total && restored.records.count == activity.records.count, "persistence")
        results.append("PASS: local-midnight split, cross-book streak, goal validation and persistence; inactive sessions ignored")

        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let fall = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00-07:00")!
        let nextDay = pacific.date(byAdding: .day, value: 1, to: fall)!
        let dst = ReadingActivityStore(directory: root.appendingPathComponent("DST"))
        dst.activateSession(token)
        dst.record(.init(start: fall, end: nextDay, kind: .listening), bookID: bookID, sessionID: token, calendar: pacific)
        try require(dst.records.count == 1 && dst.records[0].listeningSeconds == nextDay.timeIntervalSince(fall), "calendar day respects DST")
        dst.endSession(token)
        results.append("PASS: calendar-day aggregation follows timezone / DST boundaries, not fixed 86400-second buckets")

        let manager = FileManager.default
        let index = root.appendingPathComponent("reading-activity.json")
        let backup = root.appendingPathComponent("activity-backup.json")
        restored.activateSession(token)
        restored.record(.init(start: today, end: today.addingTimeInterval(5), kind: .reading), bookID: bookID, sessionID: token, calendar: calendar)
        try manager.moveItem(at: index, to: backup)
        try manager.createDirectory(at: index, withIntermediateDirectories: true)
        restored.flush()
        try require(restored.persistenceError != nil && !restored.setGoal(minutes: 60) && restored.goalMinutes == 30, "write failure doesn't commit goal")
        try manager.removeItem(at: index)
        try manager.moveItem(at: backup, to: index)
        restored.flush()
        try require(restored.persistenceError == nil && ReadingActivityStore(directory: root).totals().total == restored.totals().total, "failed record save can retry")
        let before = restored.totals().total
        try restored.anonymizeBook(bookID)
        try restored.anonymizeBook(otherID)
        try restored.anonymizeBook(otherID)
        try require(restored.records.allSatisfy { $0.bookID == nil } && restored.totals().total == before && Set(restored.records.map(\.id)).count == restored.records.count, "anonymous merge is idempotent")
        results.append("PASS: failed writes preserve pending time and goal; retries succeed; anonymization merges without losing totals")

        let corruptRoot = root.appendingPathComponent("Corrupt")
        try manager.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptFile = corruptRoot.appendingPathComponent("reading-activity.json")
        let original = Data("corrupt statistics - preserve until reset".utf8)
        try original.write(to: corruptFile)
        let corrupt = ReadingActivityStore(directory: corruptRoot)
        corrupt.activateSession(token)
        corrupt.record(.init(start: base, end: today, kind: .reading), bookID: bookID, sessionID: token)
        corrupt.flush()
        try require(corrupt.persistenceError != nil && !corrupt.setGoal(minutes: 10) && (try Data(contentsOf: corruptFile)) == original, "corrupt data guard")
        try require(corrupt.reset() && corrupt.persistenceError == nil && ReadingActivityStore(directory: corruptRoot).records.isEmpty, "explicit reset repairs statistics")
        results.append("PASS: corrupt statistics stay intact and cannot be overwritten until explicit reset")

        let library = LibraryStore(directory: root.appendingPathComponent("Integration"))
        guard let book = await library.importBook(from: source) else { throw failure("integration fixture") }
        library.updateLocation(bookID: book.id, locatorJSON: nil, position: 2, total: 5, progression: 0.4)
        let mark = ReaderMark(id: UUID(), kind: .highlight, locatorJSON: "{}", chapter: "正文", excerpt: "测试", note: "不受统计影响", color: .yellow, createdAt: base)
        try library.saveReaderMark(mark, for: book.id)
        let session = ReadingActivitySession(bookID: book.id, store: library.activity)
        session.update(state, interaction: true, now: base, uptime: 100)
        session.update(state, now: base.addingTimeInterval(10), uptime: 110)
        session.update(.init(), now: base.addingTimeInterval(15), uptime: 115)
        let integrated = library.activity.totals().total
        try require(integrated == 15, "session close flush")
        library.delete(book)
        try require(library.activity.totals(bookID: book.id).total == integrated && library.restore(book), "soft delete / restore preserves statistics")
        try require(library.activity.setGoal(minutes: 45) && library.activity.reset(), "reset")
        try require(library.books.first?.locator.fraction == 0.4 && library.readerMarks(for: book.id) == [mark] && library.activity.goalMinutes == 45, "statistics reset leaves library and goal intact")
        library.activity.activateSession(token)
        library.activity.record(.init(start: base, end: today, kind: .reading), bookID: book.id, sessionID: token, calendar: calendar)
        library.flushPendingChanges()
        let integrationRoot = root.appendingPathComponent("Integration")
        let activityFile = integrationRoot.appendingPathComponent("reading-activity.json")
        let savedActivity = try Data(contentsOf: activityFile)
        try Data("broken activity".utf8).write(to: activityFile, options: .atomic)
        let damaged = LibraryStore(directory: integrationRoot)
        damaged.delete(book)
        try require(!damaged.permanentlyDelete(book) && damaged.deletedBooks.count == 1 && manager.fileExists(atPath: integrationRoot.appendingPathComponent("Books/\(book.fileName)").path), "corrupt activity blocks partial purge")
        try savedActivity.write(to: activityFile, options: .atomic)
        let repaired = LibraryStore(directory: integrationRoot)
        try require(repaired.restore(book), "restore after corrupt stats guard")
        // Use the reloaded library so the final delete exercises persisted data.
        repaired.delete(book)
        try require(repaired.permanentlyDelete(book), "permanent deletion integration")
        let final = LibraryStore(directory: root.appendingPathComponent("Integration"))
        try require(final.activity.totals().total == 20 && final.activity.records.allSatisfy { $0.bookID == nil }, "permanent deletion anonymizes activity")
        results.append("PASS: session close flushes; soft delete / restore preserves stats; reset preserves books/notes/progress/goal; permanent delete anonymizes")
        return results
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        if try !condition() { throw failure(name) }
    }
    private static func failure(_ name: String) -> NSError { NSError(domain: "ReadingActivityRegression: \(name)", code: 1) }
}

/// Mount the real ReaderView so onAppear, Readium readiness, scene lifecycle
/// and the heartbeat are exercised, not just the pure accounting clock.
struct ReadingActivityLiveProbe: View {
    @StateObject private var library = LibraryStore(directory: URL.cachesDirectory.appendingPathComponent("ActivityLive-\(UUID().uuidString)", isDirectory: true))
    @State private var book: Book?
    var body: some View {
        Group {
            if let book {
                NavigationStack { ReaderView(book: book, library: library) }
                    .task(id: book.id) {
                        do {
                            try await Task.sleep(for: .seconds(12))
                            library.activity.flush()
                            let total = library.activity.totals(bookID: book.id)
                            let report = total.reading >= 3 && total.reading <= 16 && total.listening == 0
                                ? "PASS: real ReaderView recorded \(total.reading) foreground seconds and zero listening seconds"
                                : "ERROR: reading=\(total.reading), listening=\(total.listening)"
                            try report.write(to: URL.documentsDirectory.appendingPathComponent("activity-live-results.txt"), atomically: true, encoding: .utf8)
                        } catch { }
                    }
            } else { ProgressView("正在验证实际阅读计时…") }
        }.task {
            guard book == nil else { return }
            try? "RUNNING".write(to: URL.documentsDirectory.appendingPathComponent("activity-live-results.txt"), atomically: true, encoding: .utf8)
            let source = URL.cachesDirectory.appendingPathComponent("activity-live-\(UUID().uuidString).txt")
            do {
                try "第一章 阅读计时\n春江潮水连海平，海上明月共潮生。\n本页用于验证实际正文可见时的计时。".write(to: source, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: source) }
                book = await library.importBook(from: source)
            } catch { }
        }
    }
}
#endif
