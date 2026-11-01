#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Runs against an isolated cache directory, never the user's library.
struct LibraryRegressionProbe: View {
    @State private var previewLibrary: LibraryStore?
    @State private var message = "正在验证书架…"
    @State private var importReport: BookImportReport?
    @State private var dedupReport: BookImportReport?

    var body: some View {
        Group {
            if let previewLibrary {
                if ProcessInfo.processInfo.arguments.contains("--preview-details"), let book = previewLibrary.books.first(where: \.isFavorite) {
                    BookDetailView(book: book, library: previewLibrary) { _ in }
                } else if ProcessInfo.processInfo.arguments.contains("--preview-import"), let importReport {
                    BookImportReportView(report: importReport)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-dedup"), let dedupReport {
                    BookImportReportView(report: dedupReport)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-library-search") {
                    LibraryFullTextSearchView(library: previewLibrary)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-activity") || ProcessInfo.processInfo.arguments.contains("--preview-activity-empty") {
                    ReadingActivityView(library: previewLibrary, onRead: { _ in })
                } else if ProcessInfo.processInfo.arguments.contains("--preview-goal") {
                    NavigationStack { ReadingGoalView(activity: previewLibrary.activity) }
                } else if ProcessInfo.processInfo.arguments.contains("--preview-collections") {
                    CollectionsView(library: previewLibrary)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-membership"), let book = previewLibrary.books.first(where: \.isFavorite) {
                    BookCollectionsView(book: book, library: previewLibrary)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-deleted") {
                    RecentlyDeletedView(library: previewLibrary)
                } else if ProcessInfo.processInfo.arguments.contains("--preview-export") {
                    AnnotationExportView(library: previewLibrary)
                } else {
                    ContentView().environmentObject(previewLibrary)
                }
            }
            else { Text(message).padding() }
        }
        .task { await run() }
    }

    private func run() async {
        let resultsURL = URL.documentsDirectory.appendingPathComponent("library-results.txt")
        try? "RUNNING".write(to: resultsURL, atomically: true, encoding: .utf8)
        let manager = FileManager.default
        let directory = URL.cachesDirectory.appendingPathComponent("BookshelfLibraryRegression", isDirectory: true)
        var results: [String] = []
        do {
            if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)

            let legacyID = UUID()
            let legacyBook = Book(id: legacyID, title: "旧版书籍", author: "作者", fileName: "legacy.epub", importedAt: .now, locator: .init(page: 2, totalPages: 5))
            let encoded = try JSONEncoder().encode(legacyBook)
            var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            for key in ["isFavorite", "isFinished", "lastOpenedAt", "sourceFormat"] { oldJSON.removeValue(forKey: key) }
            let decoded = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            try require(!decoded.isFavorite && !decoded.isFinished && decoded.locator.fraction == 0.5, "legacy decoding")
            results.append("PASS: old book and locator JSON decode with defaults")

            let first = directory.appendingPathComponent("春江夜读.txt")
            let broken = directory.appendingPathComponent("损坏文件.epub")
            let second = directory.appendingPathComponent("山间来信.txt")
            try "第一章 月光\n春江潮水连海平，海上明月共潮生。\n第二章 夜色\n江畔何人初见月，江月何年初照人。".write(to: first, atomically: true, encoding: .utf8)
            try "not an epub".write(to: broken, atomically: true, encoding: .utf8)
            try "第一章 来信\n山风吹过窗前，我收到了远方的信。".write(to: second, atomically: true, encoding: .utf8)
            let storeDirectory = directory.appendingPathComponent("Library", isDirectory: true)
            let library = LibraryStore(directory: storeDirectory)
            let report = await library.importBooks(from: [first, broken, second])
            try require(report.imported.count == 2 && report.failures.count == 1 && report.failures[0].fileName == broken.lastPathComponent, "batch failure isolation")
            try require(!library.isImporting && library.importProgress == nil, "import state cleanup")
            let files = try manager.contentsOfDirectory(at: storeDirectory.appendingPathComponent("Books"), includingPropertiesForKeys: nil)
            try require(files.count == 2, "failed import cleanup")
            results.append("PASS: valid / broken / valid batch imports two books and cleans the failed file")

            let book = report.imported[0]
            library.toggleFavorite(book)
            library.recordOpened(bookID: book.id)
            library.updateLocation(bookID: book.id, locatorJSON: nil, position: 2, total: 8, progression: 0.371)
            try require(library.editBook(bookID: book.id, title: " 春江夜读 ", author: " 张若虚 ", isFavorite: true, isFinished: false), "metadata edit")
            try require(!library.editBook(bookID: book.id, title: " \n ", author: "作者"), "empty title rejected")
            library.toggleFinished(report.imported[1])
            library.flushPendingChanges()
            let restored = LibraryStore(directory: storeDirectory)
            let restoredBook = restored.books.first(where: { $0.id == book.id })!
            try require(restoredBook.title == "春江夜读" && restoredBook.author == "张若虚" && restoredBook.isFavorite && restoredBook.lastOpenedAt != nil && restoredBook.sourceFormat == "TXT", "metadata persistence")
            try require(abs(restoredBook.locator.fraction - 0.371) < 0.000001, "exact progress persistence")
            results.append("PASS: metadata, favorite, reading history, finished state and exact 37.1% progress survive reload")
            restored.updateLocation(bookID: book.id, locatorJSON: nil, position: 3, total: 8, progression: 0.42)
            restored.updateLocation(bookID: book.id, locatorJSON: nil, position: 3, total: 8, progression: 0.43)
            try await Task.sleep(for: .milliseconds(1100))
            let afterDebounce = LibraryStore(directory: storeDirectory)
            try require(afterDebounce.books.first(where: { $0.id == book.id })?.locator.fraction == 0.43, "debounced progress write")
            results.append("PASS: consecutive progress updates coalesce and persist the latest position")

            try require(LibraryOrganization.books(restored.books, query: " 张若虚 ", filter: .favorites, sort: .title).map(\.id) == [book.id], "query and favorite filter")
            try require(LibraryOrganization.books(restored.books, query: "", filter: .reading, sort: .recent).map(\.id) == [book.id], "reading filter")
            try require(LibraryOrganization.books(restored.books, query: "", filter: .finished, sort: .recent).count == 1, "finished filter")
            try require(LibraryOrganization.books(restored.books, query: "", filter: .unread, sort: .recent).isEmpty, "unread filter")
            try require(LibraryOrganization.books(restored.books, query: "", filter: .all, sort: .recent).first?.id == book.id, "recent sort")
            try require(LibraryOrganization.books(restored.books, query: "", filter: .all, sort: .progress).first?.isFinished == true, "progress sort")
            results.append("PASS: search, reading filters and sorting")

            let model = ReadiumReaderModel(book: restoredBook, store: restored)
            model.setSleepTimer(minutes: 15)
            try require(abs(model.sleepTimerEnd!.timeIntervalSinceNow - 900) < 2, "sleep deadline")
            model.checkSleepTimer(now: model.sleepTimerEnd!.addingTimeInterval(1))
            try require(model.sleepTimerEnd == nil, "sleep expiration")
            model.setSleepTimer(minutes: 30)
            model.cancelSleepTimer()
            try require(model.sleepTimerEnd == nil, "sleep cancellation")
            model.setSleepTimer(minutes: 15)
            model.close()
            try require(model.sleepTimerEnd == nil, "sleep close cleanup")
            results.append("PASS: sleep timer deadline, expiration, cancellation and leaving reader")
            results += try await OrganizationRegressionChecks.run(directory: directory, source: first)
            results += try await ImportSearchRegressionChecks.run(directory: directory)
            results += try await ReadingActivityRegressionChecks.run(directory: directory, source: first)
            // Seed only the isolated preview library for native-screen visual checks.
            restored.saveCollection(name: "诗词与散文")
            restored.saveCollection(name: "睡前阅读")
            restored.setCollections(Set(restored.collections.map(\.id)), for: book.id)
            let previewMark = ReaderMark(id: UUID(), kind: .highlight, locatorJSON: "{}", chapter: "第一章 月光", excerpt: "春江潮水连海平，海上明月共潮生。", note: "适合睡前慢慢读的一段。", color: .yellow, createdAt: Date())
            try restored.saveReaderMark(previewMark, for: book.id)
            if !ProcessInfo.processInfo.arguments.contains("--preview-activity-empty") {
                let token = UUID()
                restored.activity.activateSession(token)
                let calendar = ReadingActivityCalendar.current
                let today = calendar.startOfDay(for: Date())
                for offset in 0..<7 {
                    let start = calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(3600)
                    let reading = Double([12, 18, 8, 25, 15, 0, 10][offset] * 60)
                    let listening = Double([9, 0, 12, 5, 0, 0, 8][offset] * 60)
                    restored.activity.record(.init(start: start, end: start.addingTimeInterval(reading), kind: .reading), bookID: book.id, sessionID: token)
                    restored.activity.record(.init(start: start.addingTimeInterval(reading), end: start.addingTimeInterval(reading + listening), kind: .listening), bookID: book.id, sessionID: token)
                }
                restored.activity.endSession(token)
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-dedup") {
                let duplicates = await restored.importBooks(from: [first, second])
                restored.delete(report.imported[1])
                let recovered = await restored.importBooks(from: [second])
                dedupReport = .init(imported: [], failures: [], restored: recovered.restored, skipped: duplicates.skipped, cancelledFileCount: 2)
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-deleted") { restored.delete(report.imported[1]) }
            results.append("PASS")
            importReport = report
            previewLibrary = restored
        } catch {
            results.append("ERROR: \(error)")
            message = results.joined(separator: "\n")
        }
        try? results.joined(separator: "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
    }

    private func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        if !condition() { throw NSError(domain: "LibraryRegression: \(name)", code: 1) }
    }
}
#endif
