#if DEBUG && targetEnvironment(simulator)
import Combine
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

/// Deterministic CPU workloads; all generated data lives in a unique QA folder.
struct PerformanceRegressionProbe: View {
    @State private var status = "正在检测性能…"
    var body: some View {
        ScrollView { Text(status).font(.caption.monospaced()).padding() }
            .task { await run() }
    }

    private func run() async {
        let output = URL.documentsDirectory.appendingPathComponent("performance-results.txt")
        try? "RUNNING".write(to: output, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("--performance-profile") ? 10 : 3))
        let root = URL.cachesDirectory.appendingPathComponent("PerformanceQA-\(UUID())", isDirectory: true)
        var lines: [String] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let books = (0..<1000).map { index in
                Book(id: UUID(), title: "测试书籍 \(1000 - index)", author: "作者 \(index % 30)", fileName: "\(index).epub", importedAt: now.addingTimeInterval(Double(index)), locator: .init())
            }
            var checksum = 0
            lines.append(measure("shelf_1000_books_30_visible_rows") {
                // Mirrors ContentView: resolve the snapshot and last ID once.
                let sorted = LibraryOrganization.books(books, query: "", filter: .all, sort: .recent)
                checksum += sorted.count
                let lastID = sorted.last?.id
                for book in sorted.prefix(30) {
                    checksum += book.id == lastID ? 1 : 2
                }
            })
            let marks = (0..<1000).map { index -> ReaderMark in
                let json = "{\"href\":\"chapter.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"position\":\(1000 - index),\"totalProgression\":\(Double(1000 - index) / 1000)}}"
                return ReaderMark(id: UUID(), kind: .highlight, locatorJSON: json, chapter: "正文", excerpt: "测试段落 \(index)", note: "一条笔记", color: .yellow, createdAt: now)
            }
            lines.append(measure("export_1000_marks") {
                let value = ReaderAnnotationExporter.make(books: [books[0]], marks: { _ in marks }, format: .text, date: now)
                checksum += value.text.utf8.count
            })
            let records = (0..<12000).map { _ in
                ReadingActivityRecord(day: "2026-01-01", bookID: UUID(), readingSeconds: 10, lastActivityAt: now)
            }
            try JSONEncoder().encode(ReadingActivitySnapshot(records: records)).write(to: root.appendingPathComponent("reading-activity.json"))
            let activity = ReadingActivityStore(directory: root)
            let token = UUID()
            activity.activateSession(token)
            lines.append(measure("activity_12000_records_100_pulses") {
                for index in 0..<100 {
                    let date = now.addingTimeInterval(Double(index * 5))
                    activity.record(.init(start: date, end: date.addingTimeInterval(5), kind: .reading), bookID: books[0].id, sessionID: token)
                }
                checksum += Int(activity.totals().total)
            })
            activity.flush()
            let sum = activity.records.reduce(0) { $0 + $1.total }
            guard abs(sum - activity.totals().total) < 0.001,
                  activity.totals(bookID: books[0].id).reading == 1500,
                  activity.totals(day: ReadingActivityCalendar.key(now), bookID: books[0].id).reading == 1500 else {
                throw failure("incremental activity aggregates diverged")
            }
            let reloaded = ReadingActivityStore(directory: root)
            guard abs(reloaded.totals().total - sum) < 0.001 else { throw failure("activity reload aggregates") }
            lines.append("PASS: incremental totals equal full-history reduction and survive reload")
            activity.record(.init(start: now, end: now.addingTimeInterval(5), kind: .reading), bookID: books[0].id, sessionID: token)
            let oldGoalCheckpoint = Task { await activity.checkpoint() }
            await Task.yield()
            guard activity.setGoal(minutes: 35) else { throw failure("checkpoint goal edit") }
            await oldGoalCheckpoint.value
            guard ReadingActivityStore(directory: root).goalMinutes == 35 else { throw failure("stale checkpoint overwrote goal") }
            activity.record(.init(start: now, end: now.addingTimeInterval(5), kind: .reading), bookID: books[0].id, sessionID: token)
            let oldBookCheckpoint = Task { await activity.checkpoint() }
            await Task.yield()
            try activity.anonymizeBook(books[0].id)
            await oldBookCheckpoint.value
            guard !ReadingActivityStore(directory: root).records.contains(where: { $0.bookID == books[0].id }) else { throw failure("stale checkpoint resurrected book identity") }
            activity.record(.init(start: now, end: now.addingTimeInterval(5), kind: .reading), bookID: books[0].id, sessionID: token)
            let oldResetCheckpoint = Task { await activity.checkpoint() }
            await Task.yield()
            guard activity.reset() else { throw failure("checkpoint reset") }
            await oldResetCheckpoint.value
            guard ReadingActivityStore(directory: root).records.isEmpty else { throw failure("stale checkpoint resurrected reset records") }
            lines.append("PASS: in-flight checkpoints cannot overwrite a new goal, anonymization or reset")

            let source = root.appendingPathComponent("large-cover.png")
            let imageFormat = UIGraphicsImageRendererFormat()
            imageFormat.scale = 1
            imageFormat.opaque = true
            let original = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 3072), format: imageFormat).image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2048, height: 3072))
            }
            try original.pngData()!.write(to: source)
            let pipeline = CoverImagePipeline()
            let request = CoverImageRequest(url: source, maxPixelSize: 240)
            let coldStart = ProcessInfo.processInfo.systemUptime
            async let first = pipeline.image(for: request)
            async let second = pipeline.image(for: request)
            let (firstImage, secondImage) = await (first, second)
            let coldMS = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
            guard let cgImage = firstImage?.cgImage, secondImage != nil,
                  max(cgImage.width, cgImage.height) <= 240 else { throw failure("cover downsampling") }
            let warmStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<30 { _ = await pipeline.image(for: request) }
            let warmMS = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
            guard await pipeline.loadCount == 1 else { throw failure("cover request coalescing / warm cache") }
            guard await pipeline.image(for: .init(url: root.appendingPathComponent("missing-cover.png"))) == nil else { throw failure("missing cover") }
            let countBeforeCancellation = await pipeline.loadCount
            let cancelledConsumer = Task { await pipeline.image(for: .init(url: source, maxPixelSize: 128)) }
            cancelledConsumer.cancel()
            let cancelledImage = await cancelledConsumer.value
            let countAfterCancellation = await pipeline.loadCount
            guard cancelledImage == nil, countAfterCancellation == countBeforeCancellation else { throw failure("cancelled cover consumer started work") }
            lines.append("cover_cold: \(String(format: "%.3f", coldMS)) ms; 30 warm hits: \(String(format: "%.3f", warmMS)) ms; decoded bytes: \(cgImage.bytesPerRow * cgImage.height)")
            lines.append("PASS: concurrent cover requests coalesced; 30 warm hits caused no decode; missing and pre-cancelled covers safe")

            let txt = root.appendingPathComponent("large.txt")
            try ("第一章 开始\n" + String(repeating: "春江潮水连海平，海上明月共潮生。这是一段用来检测转换的正文。\n", count: 50_000)).write(to: txt, atomically: true, encoding: .utf8)
            var heartbeats = 0
            var maxGap = 0.0
            var previous = ProcessInfo.processInfo.systemUptime
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    maxGap = max(maxGap, now - previous)
                    previous = now
                    heartbeats += 1
                }
            }
            let convertStart = ProcessInfo.processInfo.systemUptime
            try await TXTImporter.convert(txt, to: root.appendingPathComponent("large.epub"), title: "性能检测")
            heartbeat.cancel()
            guard heartbeats > 0 else { throw failure("TXT conversion starved main actor") }
            lines.append("txt_50000_paragraphs: \(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - convertStart) * 1000)) ms; main heartbeat count: \(heartbeats); max gap: \(String(format: "%.1f", maxGap * 1000)) ms")
            let library = LibraryStore(directory: root.appendingPathComponent("Library"))
            let model = ReadiumReaderModel(book: books[0], store: library)
            let parser = EPUBParser()
            let publication = try await parser.openPublication(url: root.appendingPathComponent("large.epub"))
            guard let synthesizer = PublicationSpeechSynthesizer(publication: publication) else { throw failure("TTS fixture") }
            var publications = 0
            let subscription = model.objectWillChange.sink { publications += 1 }
            for _ in 0..<1000 { model.publicationSpeechSynthesizer(synthesizer, stateDidChange: .stopped) }
            guard publications == 0 else { throw failure("unchanged TTS state republishes UI") }
            withExtendedLifetime(subscription) {}
            lines.append("PASS: 1000 unchanged TTS state callbacks caused zero UI publications")
            let autoRoot = root.appendingPathComponent("AutomaticCheckpoint")
            let auto = ReadingActivityStore(directory: autoRoot)
            auto.activateSession(token)
            auto.record(.init(start: now, end: now.addingTimeInterval(5), kind: .reading), bookID: books[0].id, sessionID: token)
            try await Task.sleep(for: .seconds(16))
            guard ReadingActivityStore(directory: autoRoot).totals().reading == 5 else { throw failure("automatic background checkpoint") }
            lines.append("PASS: automatic 15-second background checkpoint persisted without explicit flush")
            lines.append("checksum=\(checksum)")
            lines.append("PASS: CPU workloads completed; timings are simulator Debug medians, not device FPS")
        } catch { lines.append("ERROR: \(error)") }
        status = lines.joined(separator: "\n")
        try? status.write(to: output, atomically: true, encoding: .utf8)
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "PerformanceRegression: \(message)", code: 1) }

    private func measure(_ name: String, _ operation: () -> Void) -> String {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            operation()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        return "\(name): \(String(format: "%.3f", samples.sorted()[1])) ms (median of 3)"
    }
}
#endif
