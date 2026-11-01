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
    @ObservedObject var library: LibraryStore
    @StateObject private var model: LibrarySearchModel
    @State private var query = ""
    @State private var scope: LibrarySearchScope = .all
    @State private var visibleCounts: [UUID: Int] = [:]

    init(library: LibraryStore) {
        self.library = library
        _model = StateObject(wrappedValue: LibrarySearchModel(library: library))
    }

    private var scopedIDs: [UUID] { scope.books(in: library.books).map(\.id) }
    private var scopeName: String { scope.name(collections: library.collections) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(selection: $scope) {
                        Text("全部书籍").tag(LibrarySearchScope.all)
                        Text("收藏").tag(LibrarySearchScope.favorites)
                        Text("正在读").tag(LibrarySearchScope.reading)
                        ForEach(library.collections) { collection in
                            Text(collection.name).tag(LibrarySearchScope.collection(collection.id))
                        }
                    } label: { Label("搜索范围", systemImage: "line.3.horizontal.decrease") }
                    LabeledContent("范围内书籍", value: "\(scopedIDs.count) 本")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if model.hasSearched {
                    Section {
                        if model.isSearching {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: Double(model.completedCount), total: Double(max(1, model.totalCount)))
                                Text("正在搜索 \(min(model.completedCount + 1, model.totalCount))/\(model.totalCount)：\(model.currentBookTitle)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("停止搜索", systemImage: "stop.circle") { model.stop() }
                        }
                        Label("\(model.groups.count) 本书 · \(model.matchCount) 处匹配", systemImage: "text.magnifyingglass")
                            .font(.subheadline)
                        if model.wasStopped {
                            Text("搜索已停止，保留已完成书籍的结果。重新搜索可从头查找。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if model.libraryChanged {
                            Text("书库已更新，重新搜索可获取最新结果。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if model.reachedResultLimit {
                            Text("已达到本次结果上限，请缩小搜索范围或使用更具体的词语。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !model.isSearching {
                            Button("重新搜索", systemImage: "arrow.clockwise", action: performSearch)
                                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scopedIDs.isEmpty)
                        }
                    }
                }
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.matches.prefix(visibleCounts[group.id] ?? 20)) { match in
                            NavigationLink {
                                ReaderView(book: group.book, library: library, initialSearchLocator: match.locator)
                            } label: {
                                FullTextMatchRow(match: match)
                            }
                        }
                        let count = min(visibleCounts[group.id] ?? 20, group.matches.count)
                        if count < group.matches.count {
                            Button("显示更多（已显示 \(count)/\(group.matches.count)）") { visibleCounts[group.id] = count + 20 }
                        }
                    } header: {
                        Text("\(group.book.title) · \(group.matches.count) 处")
                    } footer: {
                        if group.wasTruncated {
                            Text("本书仅收录前 \(group.matches.count) 处匹配，更多结果可在书内继续搜索。")
                        }
                    }
                }
                if !model.failedBooks.isEmpty {
                    Section("未能搜索的书籍") {
                        ForEach(model.failedBooks) { book in Text(book.title).foregroundStyle(.secondary) }
                    }
                }
                if !model.hasSearched {
                    ContentUnavailableView(scopedIDs.isEmpty ? "这个范围还没有书籍" : "搜索书籍正文", systemImage: "text.magnifyingglass", description: Text(scopedIDs.isEmpty ? "选择其他范围，或先把书籍加入书单 / 收藏。" : "在“\(scopeName)”中查找词语，支持 EPUB 与 TXT。"))
                        .listRowBackground(Color.clear)
                } else if !model.isSearching && model.groups.isEmpty && model.failedBooks.isEmpty && !model.wasStopped && !model.libraryChanged {
                    ContentUnavailableView.search(text: model.searchedTerm).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("全文搜索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书籍正文")
            .onSubmit(of: .search) { performSearch() }
        }
        .onDisappear { model.stop() }
        .onChange(of: scope) { _, _ in model.resetForScope(); visibleCounts = [:] }
        .onChange(of: scopedIDs) { _, _ in model.reconcileLibrary(scope: scope) }
        .onChange(of: library.collections) { _, collections in
            if case .collection(let id) = scope, !collections.contains(where: { $0.id == id }) { scope = .all }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--preview-library-search"), !model.hasSearched {
                query = "春江"
                performSearch()
            }
            #endif
        }
    }

    private func performSearch() {
        visibleCounts = [:]
        model.search(query, scope: scope)
    }
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
