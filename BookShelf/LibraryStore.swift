import Foundation
import SwiftUI
import Combine
import ReadiumShared

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var isImporting = false
    @Published var errorMessage: String?

    private let parser = EPUBParser()
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        removeLegacyKokoroData()
        loadIndex()
    }

    func importBook(from sourceURL: URL) async -> Book? {
        isImporting = true
        defer { isImporting = false }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let destination = booksDirectory.appendingPathComponent("\(id.uuidString).epub")
        do {
            try ensureDirectories()
            switch sourceURL.pathExtension.lowercased() {
            case "epub":
                try fileManager.copyItem(at: sourceURL, to: destination)
            case "txt":
                try await TXTImporter.convert(
                    sourceURL,
                    to: destination,
                    title: sourceURL.deletingPathExtension().lastPathComponent
                )
            default:
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let document = try await parser.parse(url: destination)
            var coverName: String?
            if let cover = document.cover {
                let name = "\(id.uuidString).cover"
                try cover.write(to: coversDirectory.appendingPathComponent(name), options: .atomic)
                coverName = name
            }
            var title = document.title
            var author = document.author
            let fallback = sourceURL.deletingPathExtension().lastPathComponent
            if title.isEmpty || title == "未命名书籍" { title = fallback.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? fallback }
            if author == "未知作者", let open = fallback.firstIndex(of: "("), let close = fallback[open...].firstIndex(of: ")") {
                let candidate = fallback[fallback.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { author = candidate }
            }
            let book = Book(id: id, title: title, author: author, fileName: destination.lastPathComponent,
                            coverFileName: coverName, importedAt: Date(), locator: ReaderLocator())
            books.insert(book, at: 0); saveIndex(); return book
        } catch {
            try? fileManager.removeItem(at: destination)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func publication(for book: Book) async throws -> Publication {
        try await parser.openPublication(url: booksDirectory.appendingPathComponent(book.fileName))
    }

    func coverURL(for book: Book) -> URL? {
        guard let name = book.coverFileName else { return nil }
        let url = coversDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func updateProgress(bookID: UUID, page: Int, total: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].locator = ReaderLocator(page: page, totalPages: total)
        saveIndex()
    }

    func updateLocation(bookID: UUID, locatorJSON: String?, position: Int, total: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].locator = ReaderLocator(page: max(0, position - 1), totalPages: total, locatorJSON: locatorJSON)
        saveIndex()
    }

    func delete(_ book: Book) {
        try? fileManager.removeItem(at: booksDirectory.appendingPathComponent(book.fileName))
        if let cover = book.coverFileName { try? fileManager.removeItem(at: coversDirectory.appendingPathComponent(cover)) }
        books.removeAll { $0.id == book.id }; saveIndex()
    }

    private var applicationSupport: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BookShelf", isDirectory: true)
    }
    private var booksDirectory: URL { applicationSupport.appendingPathComponent("Books", isDirectory: true) }
    private var coversDirectory: URL { applicationSupport.appendingPathComponent("Covers", isDirectory: true) }
    private var indexURL: URL { applicationSupport.appendingPathComponent("library.json") }

    /// Kokoro was removed from the app. Clear its large downloaded model and
    /// obsolete preferences once the updated app is launched.
    private func removeLegacyKokoroData() {
        let modelDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro-v1.1-int8", isDirectory: true)
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try? fileManager.removeItem(at: modelDirectory)
        }
        let defaults = UserDefaults.standard
        ["speech.engine", "speech.kokoroVoice", "speech.kokoroSpeed"].forEach(defaults.removeObject(forKey:))
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
    }
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL), let saved = try? decoder.decode([Book].self, from: data) else { return }
        books = saved.filter { fileManager.fileExists(atPath: booksDirectory.appendingPathComponent($0.fileName).path) }
            .sorted { $0.importedAt > $1.importedAt }
    }
    private func saveIndex() {
        do { try ensureDirectories(); try encoder.encode(books).write(to: indexURL, options: .atomic) }
        catch { errorMessage = "无法保存书架：\(error.localizedDescription)" }
    }
}
