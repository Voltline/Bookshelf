import Combine
import Foundation

enum ReadingActivityKind: String, Codable { case reading, listening }

struct ReadingActivityInterval {
    let start: Date
    let end: Date
    let kind: ReadingActivityKind
}

struct ReadingActivityRecord: Codable, Identifiable {
    let day: String
    var bookID: UUID?
    var readingSeconds: Double = 0
    var listeningSeconds: Double = 0
    var lastActivityAt: Date
    var id: String { day + ":" + (bookID?.uuidString ?? "anonymous") }
    var total: Double { readingSeconds + listeningSeconds }
}

struct ReadingActivitySnapshot: Codable {
    var version = 1
    var goalMinutes = 20
    var records: [ReadingActivityRecord] = []
}

nonisolated enum ReadingActivityCalendar {
    static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func key(_ date: Date, calendar: Calendar = current) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
}

struct ReadingActivityTotals {
    var reading: Double = 0
    var listening: Double = 0
    var total: Double { reading + listening }
}

@MainActor
final class ReadingActivityStore: ObservableObject {
    @Published private(set) var records: [ReadingActivityRecord] = []
    @Published private(set) var goalMinutes = 20
    @Published private(set) var persistenceError: String?
    private let url: URL
    private var dirty = false
    private var loadFailed = false
    private var saveTask: Task<Void, Never>?
    private var activeSession: UUID?
    var isAvailable: Bool { !loadFailed }

    init(directory: URL) {
        url = directory.appendingPathComponent("reading-activity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(ReadingActivitySnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1, (0...240).contains(snapshot.goalMinutes),
                  Set(snapshot.records.map(\.id)).count == snapshot.records.count,
                  snapshot.records.allSatisfy({ $0.readingSeconds.isFinite && $0.listeningSeconds.isFinite && $0.readingSeconds >= 0 && $0.listeningSeconds >= 0 && $0.total <= 172_800 && Self.validDay($0.day) })
            else { throw CocoaError(.fileReadCorruptFile) }
            records = snapshot.records
            goalMinutes = snapshot.goalMinutes
        } catch {
            loadFailed = true
            persistenceError = "无法读取阅读统计，原文件已保留，不影响书籍和笔记：\(error.localizedDescription)"
        }
    }

    private static func validDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return false }
        let calendar = ReadingActivityCalendar.current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return false }
        return ReadingActivityCalendar.key(date, calendar: calendar) == value
    }

    func activateSession(_ id: UUID) { activeSession = id }
    func isActiveSession(_ id: UUID) -> Bool { activeSession == id }
    func endSession(_ id: UUID) { if activeSession == id { activeSession = nil }; flush() }

    func record(_ interval: ReadingActivityInterval, bookID: UUID, sessionID: UUID, calendar: Calendar = ReadingActivityCalendar.current) {
        guard activeSession == sessionID, !loadFailed else { return }
        let duration = interval.end.timeIntervalSince(interval.start)
        guard duration.isFinite, duration > 0, duration <= 172_800 else { return }
        var updated = records
        var cursor = interval.start
        while cursor < interval.end {
            let day = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > cursor else { return }
            let end = min(next, interval.end)
            let key = ReadingActivityCalendar.key(cursor, calendar: calendar)
            let index: Int
            if let existing = updated.firstIndex(where: { $0.day == key && $0.bookID == bookID }) { index = existing }
            else { updated.append(.init(day: key, bookID: bookID, lastActivityAt: end)); index = updated.count - 1 }
            let seconds = end.timeIntervalSince(cursor)
            if interval.kind == .reading { updated[index].readingSeconds += seconds }
            else { updated[index].listeningSeconds += seconds }
            updated[index].lastActivityAt = max(updated[index].lastActivityAt, end)
            cursor = end
        }
        records = updated
        dirty = true
        // A fixed checkpoint, not a debounce that can be postponed forever.
        if saveTask == nil {
            saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.flush()
            }
        }
    }

    func totals(day: String? = nil, bookID: UUID? = nil) -> ReadingActivityTotals {
        records.lazy.filter { (day == nil || $0.day == day) && (bookID == nil || $0.bookID == bookID) }
            .reduce(into: ReadingActivityTotals()) { $0.reading += $1.readingSeconds; $0.listening += $1.listeningSeconds }
    }

    func streak(now: Date, calendar: Calendar = ReadingActivityCalendar.current) -> Int {
        let totals = Dictionary(grouping: records, by: \.day).mapValues { $0.reduce(0) { $0 + $1.total } }
        let days = Set(totals.filter { $0.value >= 60 }.keys)
        var day = calendar.startOfDay(for: now)
        if !days.contains(ReadingActivityCalendar.key(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(ReadingActivityCalendar.key(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    @discardableResult
    func setGoal(minutes: Int) -> Bool {
        guard (0...240).contains(minutes), !loadFailed else { return false }
        do { try persist(records: records, goal: minutes); goalMinutes = minutes; return true }
        catch { persistenceError = "无法保存每日目标：\(error.localizedDescription)"; return false }
    }

    /// Retain only anonymous daily totals after a book is permanently deleted.
    func anonymizeBook(_ id: UUID) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        guard records.contains(where: { $0.bookID == id }) else { return }
        var updated = records.filter { $0.bookID != id }
        for record in records where record.bookID == id {
            if let index = updated.firstIndex(where: { $0.day == record.day && $0.bookID == nil }) {
                updated[index].readingSeconds += record.readingSeconds
                updated[index].listeningSeconds += record.listeningSeconds
                updated[index].lastActivityAt = max(updated[index].lastActivityAt, record.lastActivityAt)
            } else {
                var anonymous = record
                anonymous.bookID = nil
                updated.append(anonymous)
            }
        }
        try persist(records: updated, goal: goalMinutes)
        records = updated
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard dirty, !loadFailed else { return }
        do { try persist(records: records, goal: goalMinutes) }
        catch { persistenceError = "阅读统计暂未保存，将在下次检查点重试：\(error.localizedDescription)" }
    }

    @discardableResult
    func reset() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ReadingActivitySnapshot(goalMinutes: goalMinutes, records: [])).write(to: url, options: .atomic)
            saveTask?.cancel(); saveTask = nil; dirty = false; loadFailed = false
            activeSession = nil; records = []; persistenceError = nil
            return true
        } catch { persistenceError = "无法清空阅读记录：\(error.localizedDescription)"; return false }
    }

    private func persist(records: [ReadingActivityRecord], goal: Int) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ReadingActivitySnapshot(goalMinutes: goal, records: records)).write(to: url, options: .atomic)
        dirty = false
        saveTask?.cancel(); saveTask = nil
        persistenceError = nil
    }
}

enum ReadingActivityFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "0 分钟" }
        if seconds < 60 { return "不足 1 分钟" }
        let minutes = Int(min(seconds / 60, Double(Int.max / 60)))
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}
