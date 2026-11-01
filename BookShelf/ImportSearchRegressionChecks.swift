#if DEBUG && targetEnvironment(simulator)
import Combine
import CryptoKit
import Foundation

enum ImportSearchRegressionChecks {
    static func run(directory: URL) async throws -> [String] {
        let manager = FileManager.default
        let root = directory.appendingPathComponent("ImportSearch", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let abc = root.appendingPathComponent("hash.bin")
        try Data("abc".utf8).write(to: abc)
        let known = try await FileFingerprint.sha256(of: abc)
        try require(known == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known SHA256")
        let large = Data(repeating: 0x61, count: 600_000)
        try large.write(to: abc)
        let largeHash = try await FileFingerprint.sha256(of: abc)
        try require(largeHash == "sha256:" + SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined(), "chunked SHA256")
        var results = ["PASS: streaming file fingerprint matches known SHA256 and multi-chunk reference"]

        let first = root.appendingPathComponent("蓝鲸随笔.txt")
        let renamed = root.appendingPathComponent("换个名字.txt")
        let second = root.appendingPathComponent("其他版本/蓝鲸随笔.txt")
        try manager.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("第一章 海面\n" + (1...45).map { "第\($0)次看到蓝鲸浮上海面。" }.joined(separator: "\n\n")).write(to: first, atomically: true, encoding: .utf8)
        try manager.copyItem(at: first, to: renamed)
        try "第一章 海底\n蓝鲸游过海底。\n\n又有蓝鲸出现。\n\n蓝鲸停了下来。\n\n蓝鲸离开。\n\n最后一只蓝鲸。".write(to: second, atomically: true, encoding: .utf8)
        let storeRoot = root.appendingPathComponent("Library", isDirectory: true)
        var store = LibraryStore(directory: storeRoot)
        let batch = await store.importBooks(from: [first, renamed, second])
        try require(batch.imported.count == 2 && batch.skipped.count == 1 && batch.failures.isEmpty, "batch dedup, different content same name")
        let book = batch.imported[0]
        let other = batch.imported[1]
        try require(batch.skipped[0].book.id == book.id, "renamed duplicate resolves to original")
        store = LibraryStore(directory: storeRoot)
        let repeated = await store.importBooks(from: [renamed])
        try require(repeated.skipped.first?.book.id == book.id && store.books.count == 2, "fingerprint persists")
        try require(try manager.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("Books").path).count == 2, "no duplicate physical file")
        results.append("PASS: renamed / repeated files are skipped across reload; same title with different content imports separately")

        store.saveCollection(name: "海洋")
        let collectionID = store.collections[0].id
        store.setCollections([collectionID], for: book.id)
        store.toggleFavorite(book)
        store.recordOpened(bookID: book.id)
        store.updateLocation(bookID: book.id, locatorJSON: nil, position: 1, total: 4, progression: 0.35)
        let note = ReaderMark(id: UUID(), kind: .highlight, locatorJSON: "{}", chapter: "海面", excerpt: "蓝鲸", note: "保留这条笔记", color: .blue, createdAt: Date())
        try store.saveReaderMark(note, for: book.id)
        store.delete(book)
        let restoreReport = await store.importBooks(from: [renamed])
        try require(restoreReport.restored.first?.id == book.id && restoreReport.imported.isEmpty && store.deletedBooks.isEmpty, "reimport restores existing book")
        let restored = store.books.first { $0.id == book.id }!
        try require(restored.locator.fraction == 0.35 && restored.collectionIDs == [collectionID] && restored.isFavorite && store.readerMarks(for: book.id) == [note], "restored data preserved")
        results.append("PASS: reimport from recently deleted restores original ID, progress, favorite, collection and notes")

        // Legacy EPUB matching uses the original retained archive, not metadata.
        let legacyEPUB = root.appendingPathComponent("旧版原书.epub")
        try manager.copyItem(at: storeRoot.appendingPathComponent("Books/\(other.fileName)"), to: legacyEPUB)
        store.flushPendingChanges()
        let index = storeRoot.appendingPathComponent("library.json")
        var snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: index))
        let otherIndex = snapshot.books.firstIndex { $0.id == other.id }!
        snapshot.books[otherIndex].sourceFingerprint = nil
        snapshot.books[otherIndex].sourceFormat = "EPUB"
        try JSONEncoder().encode(snapshot).write(to: index, options: .atomic)
        store = LibraryStore(directory: storeRoot)
        let legacy = await store.importBooks(from: [legacyEPUB])
        try require(legacy.skipped.first?.book.id == other.id && store.books.count == 2, "legacy EPUB duplicate")
        try require(LibraryStore(directory: storeRoot).books.first { $0.id == other.id }?.sourceFingerprint != nil, "legacy fingerprint backfill")
        results.append("PASS: old EPUB archives are recognized and matching fingerprints backfill safely")

        let cancelStore = LibraryStore(directory: root.appendingPathComponent("Cancellation", isDirectory: true))
        let observer = cancelStore.$importProgress.sink { progress in
            if progress?.completed == 0 { cancelStore.cancelImport() }
        }
        let canceled = await cancelStore.importBooks(from: [first, second, renamed])
        observer.cancel()
        try require(canceled.imported.count == 1 && canceled.cancelledFileCount == 2 && canceled.failures.isEmpty, "stop after current file")
        try require(!cancelStore.isImporting && !cancelStore.importCancellationRequested && cancelStore.importProgress == nil, "cancel state cleanup")
        let continued = await cancelStore.importBooks(from: [second])
        try require(continued.imported.count == 1 && cancelStore.books.count == 2, "new import after cancellation")
        results.append("PASS: stopping batch import completes current file, counts untouched files and allows next import")

        try require(LibrarySearchScope.favorites.books(in: store.books).map(\.id) == [book.id], "favorite scope")
        try require(LibrarySearchScope.reading.books(in: store.books).map(\.id) == [book.id], "reading scope")
        try require(LibrarySearchScope.collection(collectionID).books(in: store.books).map(\.id) == [book.id], "collection scope")
        let search = LibrarySearchModel(library: store)
        search.search("  蓝鲸  ", scope: .all)
        try await waitForSearch(search)
        try require(search.groups.count == 2 && search.matchCount == 50 && search.failedBooks.isEmpty && search.completedCount == 2, "whole library search")
        search.search("蓝鲸", scope: .collection(collectionID))
        try await waitForSearch(search)
        try require(search.groups.map(\.id) == [book.id] && search.matchCount == 45, "scoped Readium search")
        search.search("蓝鲸", scope: .favorites)
        try await waitForSearch(search)
        try require(search.groups.map(\.id) == [book.id], "favorites Readium search")
        let limited = LibrarySearchModel(library: store, resultLimit: 5, perBookLimit: 3)
        limited.search("蓝鲸", scope: .all)
        try await waitForSearch(limited)
        try require(limited.matchCount == 5 && limited.reachedResultLimit && limited.groups.allSatisfy { $0.matches.count <= 3 }, "bounded search")
        results.append("PASS: collection / favorite / reading scopes and actual Readium search; 50 matches; per-book and overall result bounds")

        search.search("蓝鲸", scope: .all)
        await Task.yield()
        search.stop()
        try require(!search.isSearching && search.wasStopped, "stop search")
        search.search("绝无此词的回归样例", scope: .all)
        try await waitForSearch(search)
        try require(search.matchCount == 0 && !search.wasStopped, "new search excludes old session results")
        search.search("蓝鲸", scope: .all)
        try await waitForSearch(search)
        store.delete(book)
        search.reconcileLibrary(scope: .all)
        try require(!search.groups.contains { $0.id == book.id } && search.libraryChanged && !search.isSearching, "remove stale deleted results")
        store.restore(book)
        search.resetForScope()
        try require(!search.hasSearched && search.groups.isEmpty, "scope reset")
        search.search("  ", scope: .all)
        try require(!search.hasSearched && !search.isSearching, "empty query")
        results.append("PASS: stopped / replaced sessions cannot leak old results; deleted books disappear and scope resets cleanly")

        let unavailable = storeRoot.appendingPathComponent("Books/\(other.fileName)")
        let backup = root.appendingPathComponent("unavailable-fixture.epub")
        try manager.moveItem(at: unavailable, to: backup)
        defer { try? manager.moveItem(at: backup, to: unavailable) }
        search.search("蓝鲸", scope: .all)
        try await waitForSearch(search)
        try require(search.failedBooks.map(\.id) == [other.id] && search.groups.map(\.id) == [book.id] && search.matchCount == 45 && search.completedCount == 2, "unavailable book failure isolation")
        results.append("PASS: an unavailable book is reported without interrupting matches in other books")
        return results
    }

    private static func waitForSearch(_ model: LibrarySearchModel) async throws {
        for _ in 0..<1000 {
            if !model.isSearching { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.stop()
        throw failure("search timed out")
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        if try !condition() { throw failure(name) }
    }
    private static func failure(_ name: String) -> NSError { NSError(domain: "ImportSearchRegression: \(name)", code: 1) }
}
#endif
