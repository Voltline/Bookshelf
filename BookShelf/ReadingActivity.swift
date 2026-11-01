import Combine
import Foundation
import os

nonisolated enum ReadingActivityKind: String, Codable, Sendable { case reading, listening }

struct ReadingActivityInterval {
    let start: Date
    let end: Date
    let kind: ReadingActivityKind
}

nonisolated struct ReadingActivityRecord: Codable, Identifiable, Sendable {
    let day: String
    var bookID: UUID?
    var readingSeconds: Double = 0
    var listeningSeconds: Double = 0
    var lastActivityAt: Date
    var id: String { day + ":" + (bookID?.uuidString ?? "anonymous") }
    var total: Double { readingSeconds + listeningSeconds }
}

nonisolated struct ReadingActivitySnapshot: Codable, Sendable {
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
    private var storedRecords: [ReadingActivityRecord] = []
    var records: [ReadingActivityRecord] { storedRecords }
    private var recordIndices: [String: Int] = [:]
    private var dailyTotals: [String: ReadingActivityTotals] = [:]
    private var bookTotals: [UUID: ReadingActivityTotals] = [:]
    private var allTotals = ReadingActivityTotals()
    @Published private(set) var goalMinutes = 20
    @Published private(set) var persistenceError: String?
    private let url: URL
    private var dirty = false
    private var loadFailed = false
    private var saveTask: Task<Void, Never>?
    private var activeSession: UUID?
    private var revision = 0
    private var persistenceGeneration = 0
    var isAvailable: Bool { !loadFailed }

    init(directory: URL) {
        url = directory.appendingPathComponent("reading-activity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(ReadingActivitySnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1, (0...240).contains(snapshot.goalMinutes),
                  Set(snapshot.records.map(\.id)).count == snapshot.records.count,
                  Set(snapshot.records.map(\.day)).allSatisfy(Self.validDay),
                  snapshot.records.allSatisfy({ $0.readingSeconds.isFinite && $0.listeningSeconds.isFinite && $0.readingSeconds >= 0 && $0.listeningSeconds >= 0 && $0.total <= 172_800 })
            else { throw CocoaError(.fileReadCorruptFile) }
            storedRecords = snapshot.records
            rebuildSummaries()
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
        objectWillChange.send()
        var cursor = interval.start
        while cursor < interval.end {
            let day = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > cursor else { return }
            let end = min(next, interval.end)
            let key = ReadingActivityCalendar.key(cursor, calendar: calendar)
            let index: Int
            let recordKey = key + ":" + bookID.uuidString
            if let existing = recordIndices[recordKey] { index = existing }
            else {
                index = storedRecords.count
                storedRecords.append(.init(day: key, bookID: bookID, lastActivityAt: end))
                recordIndices[recordKey] = index
            }
            let seconds = end.timeIntervalSince(cursor)
            if interval.kind == .reading {
                storedRecords[index].readingSeconds += seconds
                dailyTotals[key, default: .init()].reading += seconds
                bookTotals[bookID, default: .init()].reading += seconds
                allTotals.reading += seconds
            } else {
                storedRecords[index].listeningSeconds += seconds
                dailyTotals[key, default: .init()].listening += seconds
                bookTotals[bookID, default: .init()].listening += seconds
                allTotals.listening += seconds
            }
            storedRecords[index].lastActivityAt = max(storedRecords[index].lastActivityAt, end)
            cursor = end
        }
        dirty = true
        revision += 1
        // A fixed checkpoint, not a debounce that can be postponed forever.
        if saveTask == nil {
            saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.checkpoint()
            }
        }
    }

    func totals(day: String? = nil, bookID: UUID? = nil) -> ReadingActivityTotals {
        if let day, let bookID {
            guard let index = recordIndices[day + ":" + bookID.uuidString] else { return .init() }
            let record = storedRecords[index]
            return .init(reading: record.readingSeconds, listening: record.listeningSeconds)
        }
        if let day { return dailyTotals[day] ?? .init() }
        if let bookID { return bookTotals[bookID] ?? .init() }
        return allTotals
    }

    func streak(now: Date, calendar: Calendar = ReadingActivityCalendar.current) -> Int {
        let days = Set(dailyTotals.filter { $0.value.total >= 60 }.keys)
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
        objectWillChange.send()
        storedRecords = updated
        rebuildSummaries()
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard dirty, !loadFailed else { return }
        do { try persist(records: records, goal: goalMinutes) }
        catch { persistenceError = "阅读统计暂未保存，将在下次检查点重试：\(error.localizedDescription)" }
    }

    /// Encode a snapshot off the UI actor. New pulses may arrive while encoding;
    /// an older checkpoint never marks those newer records as already saved.
    func checkpoint() async {
        guard dirty, !loadFailed else { return }
        let savedRevision = revision
        let savedGeneration = persistenceGeneration
        do {
            let data = try await LibrarySnapshotEncoding.activity(.init(goalMinutes: goalMinutes, records: storedRecords))
            try Task.checkCancellation()
            guard savedGeneration == persistenceGeneration else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            persistenceGeneration += 1
            if revision == savedRevision { dirty = false }
            persistenceError = nil
        } catch is CancellationError { return }
        catch { persistenceError = "阅读统计暂未保存，将在下次检查点重试：\(error.localizedDescription)" }
        saveTask = nil
        if dirty {
            saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.checkpoint()
            }
        }
    }

    @discardableResult
    func reset() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ReadingActivitySnapshot(goalMinutes: goalMinutes, records: [])).write(to: url, options: .atomic)
            saveTask?.cancel(); saveTask = nil; dirty = false; loadFailed = false
            persistenceGeneration += 1
            objectWillChange.send()
            activeSession = nil; storedRecords = []; persistenceError = nil
            rebuildSummaries()
            return true
        } catch { persistenceError = "无法清空阅读记录：\(error.localizedDescription)"; return false }
    }

    private func persist(records: [ReadingActivityRecord], goal: Int) throws {
        let trace = PerformanceTrace.signposter.beginInterval("ActivityPersist", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ActivityPersist", trace) }
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ReadingActivitySnapshot(goalMinutes: goal, records: records)).write(to: url, options: .atomic)
        persistenceGeneration += 1
        dirty = false
        saveTask?.cancel(); saveTask = nil
        persistenceError = nil
    }

    /// Rebuild only after loading or destructive edits. Live pulses update the
    /// target bucket and aggregates in O(1), without copying the whole history.
    private func rebuildSummaries() {
        recordIndices = [:]; dailyTotals = [:]; bookTotals = [:]; allTotals = .init()
        for (index, record) in storedRecords.enumerated() {
            recordIndices[record.id] = index
            dailyTotals[record.day, default: .init()].reading += record.readingSeconds
            dailyTotals[record.day, default: .init()].listening += record.listeningSeconds
            if let id = record.bookID {
                bookTotals[id, default: .init()].reading += record.readingSeconds
                bookTotals[id, default: .init()].listening += record.listeningSeconds
            }
            allTotals.reading += record.readingSeconds
            allTotals.listening += record.listeningSeconds
        }
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
