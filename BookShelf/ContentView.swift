import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let epub = UTType(filenameExtension: "epub") ?? .data
    static let txt = UTType(filenameExtension: "txt") ?? .plainText
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var isImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var selectedTab: HomeTab = .library
    @State private var libraryPath: [Book] = []
    @AppStorage("library.lastOpenedBookID") private var lastOpenedBookID = ""
    @State private var searchText = ""
    @State private var pendingDeletion: Book?

    private enum HomeTab: Hashable {
        case library, fullText, online
    }

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return library.books }
        return library.books.filter { $0.title.localizedStandardContains(searchText) || $0.author.localizedStandardContains(searchText) }
    }

    private var continueReadingBook: Book? {
        if let lastOpened = library.books.first(where: { $0.id.uuidString == lastOpenedBookID }) {
            return lastOpened
        }
        return library.books.first(where: { $0.locator.locatorJSON != nil || $0.locator.page > 0 })
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryTab
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(HomeTab.library)

            LibraryFullTextSearchView(library: library)
                .tabItem { Label("全文搜索", systemImage: "text.magnifyingglass") }
                .tag(HomeTab.fullText)

            OnlineSearchView()
                .tabItem { Label("在线找书", systemImage: "globe") }
                .tag(HomeTab.online)
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.epub, .txt], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
                return
            }
            Task { _ = await library.importBook(from: url) }
        }
        .sheet(isPresented: $isSettingsPresented) { AppSettingsView() }
        .alert("无法完成操作", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "未知错误") }
        .confirmationDialog("要移除这本书吗？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("从书架删除", role: .destructive) { if let book = pendingDeletion { library.delete(book) }; pendingDeletion = nil }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { Text("文件会从本机删除，无法撤销。") }
        .overlay { if library.isImporting { importingOverlay } }
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            Group {
                if library.books.isEmpty { emptyLibrary }
                else { bookList }
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { isImporterPresented = true } label: { Label("导入书籍", systemImage: "plus") }
                        .disabled(library.isImporting)
                    Button { isSettingsPresented = true } label: { Label("设置", systemImage: "gearshape") }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
            .navigationDestination(for: Book.self) { book in ReaderView(book: book, library: library) }
        }
    }

    private var bookList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searchText.isEmpty, let book = continueReadingBook {
                    Text("继续阅读")
                        .font(.title3.weight(.semibold))
                        .padding(.bottom, 12)
                    Button { open(book) } label: {
                        ContinueReadingCard(book: book, coverURL: library.coverURL(for: book))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 28)
                }

                HStack {
                    Text(searchText.isEmpty ? "全部书籍" : "搜索结果")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(filteredBooks.count) 本")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)

                ForEach(filteredBooks) { book in
                    Button { open(book) } label: {
                        ShelfBookRow(book: book, coverURL: library.coverURL(for: book))
                    }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { pendingDeletion = book } label: { Label("删除", systemImage: "trash") }
                        }
                    if book.id != filteredBooks.last?.id {
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay {
            if filteredBooks.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
    }

    private func open(_ book: Book) {
        lastOpenedBookID = book.id.uuidString
        libraryPath.append(book)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("书架是空的", systemImage: "books.vertical")
        } description: {
            Text("导入 EPUB 或 TXT，开始阅读或聆听。")
        } actions: {
            Button { isImporterPresented = true } label: { Label("导入书籍", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.16).ignoresSafeArea()
            VStack(spacing: 14) { ProgressView(); Text("正在导入并解析…").font(.callout) }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct ContinueReadingCard: View {
    let book: Book
    let coverURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(title: book.title, url: coverURL)
                .frame(width: 70, height: 102)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if book.locator.page > 0 && book.locator.totalPages > 1 {
                    ProgressView(value: book.locator.fraction)
                        .tint(.accentColor)
                }
                Text(book.locator.page > 0 && book.locator.totalPages > 1 ? "继续阅读 · 已读 \(Int((book.locator.fraction * 100).rounded()))%" : "继续阅读")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityHint("继续阅读")
    }
}

private struct ShelfBookRow: View {
    let book: Book
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            BookCover(title: book.title, url: coverURL, showsTitle: false)
                .frame(width: 56, height: 78)
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if book.locator.page > 0 && book.locator.totalPages > 1 {
                    Text("已读 \(Int((book.locator.fraction * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开书籍")
    }
}

private struct BookCover: View {
    let title: String
    let url: URL?
    var showsTitle = true
    @State private var image: Image?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.9), .blue.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { image.resizable().scaledToFill() }
            else {
                VStack(spacing: 7) {
                    Image(systemName: "book.closed.fill")
                        .font(showsTitle ? .title3 : .title2)
                        .foregroundStyle(.white.opacity(0.85))
                    if showsTitle {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                    }
                }
            }
        }
        .task(id: url) {
            image = nil
            guard let url, let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) else { return }
            image = Image(uiImage: uiImage)
        }
    }
}

#Preview { ContentView().environmentObject(LibraryStore()) }
