import Combine
import Foundation
import ReadiumShared

enum LibrarySearchScope: Hashable {
    case all, favorites, reading, collection(UUID)

    func books(in library: [Book]) -> [Book] {
        library.filter { book in
            guard book.deletedAt == nil else { return false }
            switch self {
            case .all: return true
            case .favorites: return book.isFavorite
            case .reading: return ShelfFilter.reading.includes(book)
            case .collection(let id): return book.collectionIDs.contains(id)
            }
        }
    }

    func name(collections: [BookCollection]) -> String {
        switch self {
        case .all: "全部书籍"
        case .favorites: "收藏"
        case .reading: "正在读"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "书单"
        }
    }
}

struct LibrarySearchGroup: Identifiable {
    let book: Book
    let matches: [BookSearchMatch]
    let wasTruncated: Bool
    var id: UUID { book.id }
}

/// One serial search session at a time; canceled sessions cannot publish late results.
@MainActor
final class LibrarySearchModel: ObservableObject {
    @Published private(set) var groups: [LibrarySearchGroup] = []
    @Published private(set) var failedBooks: [Book] = []
    @Published private(set) var currentBookTitle = ""
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var searchedTerm = ""
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published private(set) var wasStopped = false
    @Published private(set) var libraryChanged = false
    @Published private(set) var reachedResultLimit = false
    private var searchTask: Task<Void, Never>?
    private var sessionID = UUID()
    private let library: LibraryStore
    private let resultLimit: Int
    private let perBookLimit: Int

    init(library: LibraryStore, resultLimit: Int = 1000, perBookLimit: Int = 200) {
        self.library = library
        self.resultLimit = max(1, resultLimit)
        self.perBookLimit = max(1, perBookLimit)
    }

    var matchCount: Int { groups.reduce(0) { $0 + $1.matches.count } }

    func search(_ query: String, scope: LibrarySearchScope) {
        stop()
        let token = sessionID
        searchedTerm = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        groups = []; failedBooks = []; completedCount = 0; currentBookTitle = ""
        wasStopped = false; libraryChanged = false; reachedResultLimit = false
        let books = scope.books(in: library.books)
        totalCount = books.count
        hasSearched = !searchedTerm.isEmpty
        guard hasSearched, !books.isEmpty else { return }
        isSearching = true
        let term = searchedTerm
        searchTask = Task { [weak self] in
            guard let self else { return }
            for book in books {
                guard !Task.isCancelled, token == sessionID else { return }
                currentBookTitle = book.title
                let remaining = resultLimit - matchCount
                guard remaining > 0 else { reachedResultLimit = true; break }
                do {
                    let publication = try await library.publication(for: book)
                    guard !Task.isCancelled, token == sessionID else { return }
                    var matches: [BookSearchMatch] = []
                    let truncated = try await FullTextSearch.search(publication: publication, query: term, limit: min(perBookLimit, remaining)) { batch in
                        matches.append(contentsOf: batch)
                    }
                    guard !Task.isCancelled, token == sessionID else { return }
                    if !matches.isEmpty { groups.append(.init(book: book, matches: matches, wasTruncated: truncated)) }
                    completedCount += 1
                    if matchCount >= resultLimit && (truncated || completedCount < totalCount) {
                        reachedResultLimit = true
                        break
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, token == sessionID else { return }
                    failedBooks.append(book)
                    completedCount += 1
                }
            }
            guard token == sessionID else { return }
            isSearching = false
            searchTask = nil
        }
    }

    func stop() {
        if isSearching { wasStopped = true }
        searchTask?.cancel()
        searchTask = nil
        sessionID = UUID()
        isSearching = false
    }

    func resetForScope() {
        stop()
        groups = []; failedBooks = []; hasSearched = false; wasStopped = false
        libraryChanged = false; reachedResultLimit = false
    }

    func reconcileLibrary(scope: LibrarySearchScope) {
        stop()
        let activeIDs = Set(scope.books(in: library.books).map(\.id))
        groups.removeAll { !activeIDs.contains($0.id) }
        failedBooks.removeAll { !activeIDs.contains($0.id) }
        libraryChanged = hasSearched
        wasStopped = false
    }
}
