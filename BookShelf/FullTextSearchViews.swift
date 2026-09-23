import ReadiumShared
import SwiftUI

struct BookFullTextSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ReadiumReaderModel
    @State private var query = ""
    @State private var searchedTerm = ""
    @State private var matches: [BookSearchMatch] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var wasTruncated = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if isSearching { Label("正在搜索正文…", systemImage: "magnifyingglass").foregroundStyle(.secondary) }
                if wasTruncated {
                    Text("结果较多，仅显示前 \(matches.count) 条；输入更具体的关键词可缩小范围。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(matches) { match in
                    Button {
                        model.go(toSearchResult: match.locator)
                        dismiss()
                    } label: {
                        FullTextMatchRow(match: match)
                    }
                    .buttonStyle(.plain)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if !hasSearched {
                    ContentUnavailableView("搜索本书正文", systemImage: "text.magnifyingglass", description: Text("输入词语，查找这本书中的所有出现位置。"))
                } else if !isSearching && matches.isEmpty && errorMessage == nil {
                    ContentUnavailableView.search(text: searchedTerm)
                }
            }
            .navigationTitle("书内搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .searchable(text: $query, prompt: "搜索本书正文")
            .onSubmit(of: .search) { performSearch() }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func performSearch() {
        searchTask?.cancel()
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        searchedTerm = term
        matches = []
        errorMessage = nil
        wasTruncated = false
        hasSearched = !term.isEmpty
        guard !term.isEmpty, let publication = model.publication else {
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            do {
                let truncated = try await FullTextSearch.search(publication: publication, query: term, limit: 600) { batch in
                    matches.append(contentsOf: batch)
                }
                guard !Task.isCancelled else { return }
                wasTruncated = truncated
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

struct LibraryFullTextSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    @State private var query = ""
    @State private var searchedTerm = ""
    @State private var groups: [LibrarySearchGroup] = []
    @State private var failedBooks: [Book] = []
    @State private var currentBookTitle = ""
    @State private var completedCount = 0
    @State private var totalCount = 0
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var wasInterrupted = false

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(completedCount), total: Double(max(1, totalCount)))
                        Text("正在搜索 \(completedCount + 1)/\(totalCount)：\(currentBookTitle)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if wasInterrupted {
                    Text("搜索已暂停，重新输入关键词并搜索可继续。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.matches) { match in
                            NavigationLink {
                                ReaderView(book: group.book, library: library, initialSearchLocator: match.locator)
                            } label: {
                                FullTextMatchRow(match: match)
                            }
                        }
                    } header: {
                        Text("\(group.book.title) · \(group.matches.count) 处")
                    } footer: {
                        if group.wasTruncated {
                            Text("本书仅显示前 \(group.matches.count) 处，可在书内继续搜索。")
                        }
                    }
                }
                if !failedBooks.isEmpty {
                    Section("未能搜索的书籍") {
                        ForEach(failedBooks) { book in Text(book.title).foregroundStyle(.secondary) }
                    }
                }
            }
            .overlay {
                if !hasSearched {
                    ContentUnavailableView("搜索已导入书籍", systemImage: "books.vertical", description: Text("在书架中所有书籍的正文里查找词语，包括已导入的 TXT。"))
                } else if !isSearching && groups.isEmpty && failedBooks.isEmpty {
                    ContentUnavailableView.search(text: searchedTerm)
                }
            }
            .navigationTitle("书架全文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searchTask?.cancel(); dismiss() } } }
            .searchable(text: $query, prompt: "搜索所有书籍正文")
            .onSubmit(of: .search) { performSearch() }
        }
        .onDisappear {
            if isSearching {
                searchTask?.cancel()
                isSearching = false
                wasInterrupted = true
            }
        }
    }

    private func performSearch() {
        searchTask?.cancel()
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        searchedTerm = term
        groups = []
        failedBooks = []
        wasInterrupted = false
        completedCount = 0
        let books = library.books
        totalCount = books.count
        hasSearched = !term.isEmpty
        guard !term.isEmpty, !books.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            for book in books {
                guard !Task.isCancelled else { return }
                currentBookTitle = book.title
                do {
                    let publication = try await library.publication(for: book)
                    var matches: [BookSearchMatch] = []
                    let truncated = try await FullTextSearch.search(publication: publication, query: term, limit: 200) { batch in
                        matches.append(contentsOf: batch)
                    }
                    guard !Task.isCancelled else { return }
                    if !matches.isEmpty {
                        groups.append(LibrarySearchGroup(book: book, matches: matches, wasTruncated: truncated))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failedBooks.append(book)
                }
                completedCount += 1
            }
            isSearching = false
        }
    }
}

private struct LibrarySearchGroup: Identifiable {
    let book: Book
    let matches: [BookSearchMatch]
    let wasTruncated: Bool
    var id: UUID { book.id }
}

private struct FullTextMatchRow: View {
    let match: BookSearchMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(match.chapter).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            snippet
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private var snippet: Text {
        let text = match.locator.text.sanitized()
        let before = String((text.before ?? "").suffix(48))
        let highlight = text.highlight ?? ""
        let after = String((text.after ?? "").prefix(68))
        return Text("…\(before)")
            + Text(highlight).bold().foregroundColor(.accentColor)
            + Text("\(after)…")
    }
}
