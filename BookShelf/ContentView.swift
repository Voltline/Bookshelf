import SwiftUI
import UniformTypeIdentifiers
import ImageIO

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
    @State private var detailsBook: Book?
    @State private var importReport: BookImportReport?
    @State private var selectedCollectionID: UUID?
    @State private var membershipBook: Book?
    @State private var showCollections = false
    @State private var showDeleted = false
    @State private var showAnnotationExport = false
    @State private var showReadingActivity = false
    @State private var filter: ShelfFilter = .all
    @AppStorage("library.layout") private var layoutRaw = ShelfLayout.list.rawValue
    @AppStorage("library.sort") private var sortRaw = ShelfSort.recent.rawValue

    private var layout: ShelfLayout { ShelfLayout(rawValue: layoutRaw) ?? .list }

    private enum HomeTab: Hashable {
        case library, fullText, online
    }

    private var filteredBooks: [Book] {
        let books = library.books.filter { book in selectedCollectionID.map { book.collectionIDs.contains($0) } ?? true }
        return LibraryOrganization.books(books, query: searchText, filter: filter, sort: ShelfSort(rawValue: sortRaw) ?? .recent)
    }

    private var shelfTitle: String {
        library.collections.first(where: { $0.id == selectedCollectionID })?.name ?? "书架"
    }

    private var continueReadingBook: Book? {
        if let recent = library.books.filter({ !$0.isFinished && $0.lastOpenedAt != nil })
            .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }) {
            return recent
        }
        if let lastOpened = library.books.first(where: { $0.id.uuidString == lastOpenedBookID && !$0.isFinished }) {
            return lastOpened
        }
        return library.books.first(where: { $0.hasStartedReading && !$0.isFinished })
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
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.epub, .txt], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else {
                if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
                return
            }
            Task {
                let report = await library.importBooks(from: urls)
                if urls.count > 1 || !report.failures.isEmpty || !report.skipped.isEmpty || !report.restored.isEmpty || report.cancelledFileCount > 0 { importReport = report }
            }
        }
        .sheet(isPresented: $isSettingsPresented) { AppSettingsView() }
        .sheet(item: $detailsBook) { book in
            BookDetailView(book: book, library: library) { book in
                detailsBook = nil
                open(book)
            }
        }
        .sheet(item: $importReport) { report in BookImportReportView(report: report) }
        .sheet(isPresented: $showCollections) {
            CollectionsView(library: library) { id in selectedCollectionID = id }
        }
        .sheet(item: $membershipBook) { BookCollectionsView(book: $0, library: library) }
        .sheet(isPresented: $showDeleted) { RecentlyDeletedView(library: library) }
        .sheet(isPresented: $showAnnotationExport) { AnnotationExportView(library: library) }
        .sheet(isPresented: $showReadingActivity) {
            ReadingActivityView(library: library) { book in
                showReadingActivity = false
                open(book)
            }
        }
        .onChange(of: library.collections) { _, collections in
            if let selectedCollectionID, !collections.contains(where: { $0.id == selectedCollectionID }) { self.selectedCollectionID = nil }
        }
        .alert("无法完成操作", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "未知错误") }
        .confirmationDialog("要移除这本书吗？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("移到最近删除", role: .destructive) { if let book = pendingDeletion { library.delete(book) }; pendingDeletion = nil }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { Text("可以在书架菜单的“最近删除”中恢复，阅读进度和笔记都会保留。") }
        .overlay { if library.isImporting { importingOverlay } }
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            Group {
                if library.books.isEmpty { emptyLibrary }
                else { bookList }
            }
            .navigationTitle(shelfTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { shelfOptions }
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
                if searchText.isEmpty, filter == .all, selectedCollectionID == nil, let book = continueReadingBook {
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
                    Menu {
                        Picker("阅读状态", selection: $filter) {
                            ForEach(ShelfFilter.allCases) { item in
                                Label(item.name, systemImage: item.symbol).tag(item)
                            }
                        }
                        Divider()
                        collectionPicker
                        Button("管理书单", systemImage: "folder.badge.gearshape") { showCollections = true }
                    } label: {
                        Label(searchText.isEmpty ? filter.name : "搜索结果", systemImage: "line.3.horizontal.decrease")
                            .font(.headline)
                    }
                    .accessibilityLabel("筛选书架：\(filter.name)")
                    Spacer()
                    Text("\(filteredBooks.count) 本")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)

                if filteredBooks.isEmpty {
                    noMatchingBooks
                        .padding(.vertical, 40)
                } else if layout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(filteredBooks) { book in
                            Button { open(book) } label: {
                                ShelfBookGridItem(book: book, coverURL: library.coverURL(for: book))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { bookActions(book) }
                            .overlay(alignment: .topLeading) {
                                Menu { bookActions(book) } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 30, height: 30)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .accessibilityLabel("管理《\(book.title)》")
                                .padding(6)
                            }
                        }
                    }
                    .padding(.top, 8)
                } else {
                    ForEach(filteredBooks) { book in
                        HStack(spacing: 8) {
                            Button { open(book) } label: {
                                ShelfBookRow(book: book, coverURL: library.coverURL(for: book))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { bookActions(book) }
                            Menu { bookActions(book) } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 32, height: 44)
                            }
                            .accessibilityLabel("管理《\(book.title)》")
                        }
                        if book.id != filteredBooks.last?.id {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                if searchText.isEmpty, filter == .all, selectedCollectionID == nil {
                    ReadingGoalSummary(activity: library.activity) { showReadingActivity = true }
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: layout == .grid ? 900 : 700)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var shelfOptions: some View {
        Menu {
            Picker("显示方式", selection: $layoutRaw) {
                ForEach(ShelfLayout.allCases) { item in Label(item.name, systemImage: item.symbol).tag(item.rawValue) }
            }
            Picker("排序", selection: $sortRaw) {
                ForEach(ShelfSort.allCases) { item in Text(item.name).tag(item.rawValue) }
            }
            Divider()
            collectionPicker
            Button("管理书单", systemImage: "folder") { showCollections = true }
            Button("阅读记录与目标", systemImage: "chart.bar.xaxis") { showReadingActivity = true }
            Button("导出划线与笔记", systemImage: "square.and.arrow.up") { showAnnotationExport = true }
            Button("最近删除（\(library.deletedBooks.count)）", systemImage: "trash") { showDeleted = true }
        } label: { Label("书架管理", systemImage: layout.symbol) }
    }

    private var collectionPicker: some View {
        Picker("书单", selection: $selectedCollectionID) {
            Text("全部书籍").tag(nil as UUID?)
            ForEach(library.collections) { collection in Text(collection.name).tag(Optional(collection.id)) }
        }
    }

    @ViewBuilder
    private var noMatchingBooks: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "这里还没有书籍" : "没有找到书籍", systemImage: filter.symbol)
        } description: {
            Text(searchText.isEmpty ? "点书籍旁的“…”可以收藏、标记读完或查看详情。" : "试试其他书名、作者或阅读状态。")
        } actions: {
            Button("显示全部书籍") { searchText = ""; filter = .all; selectedCollectionID = nil }
        }
    }

    @ViewBuilder
    private func bookActions(_ book: Book) -> some View {
        Button { detailsBook = book } label: { Label("书籍详情", systemImage: "info.circle") }
        Button { membershipBook = book } label: { Label("加入书单", systemImage: "folder.badge.plus") }
        Button { library.toggleFavorite(book) } label: {
            Label(book.isFavorite ? "取消收藏" : "收藏", systemImage: book.isFavorite ? "star.slash" : "star")
        }
        Button { library.toggleFinished(book) } label: {
            Label(book.isFinished ? "取消已读完标记" : "标记为已读完", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { pendingDeletion = book } label: { Label("删除", systemImage: "trash") }
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
            VStack(spacing: 14) {
                if let progress = library.importProgress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("正在导入 \(progress.completed + 1)/\(progress.total)").font(.headline)
                    Text(progress.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(library.importCancellationRequested ? "正在完成当前文件…" : (progress.stage == .checking ? "正在检查是否重复…" : "正在解析书籍…"))
                        .font(.caption).foregroundStyle(.secondary)
                } else { ProgressView("正在准备导入…") }
                Button("停止后续导入", role: .cancel) { library.cancelImport() }
                    .disabled(library.importCancellationRequested)
                Text("停止后会保留已导入的书籍。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 240)
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
                if book.hasStartedReading {
                    ProgressView(value: book.locator.fraction)
                        .tint(.accentColor)
                }
                Text(book.hasStartedReading ? "继续阅读 · \(book.progressLabel)" : "开始阅读")
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

private struct ShelfBookGridItem: View {
    let book: Book
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCover(title: book.title, url: coverURL)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if book.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(7)
                            .background(.regularMaterial, in: Circle())
                            .padding(6)
                    }
                }
            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .frame(minHeight: 40, alignment: .topLeading)
            Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(book.progressLabel).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开书籍，长按可管理")
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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(book.title).font(.body.weight(.medium)).lineLimit(2)
                    if book.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
                }
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Label(book.progressLabel, systemImage: book.isFinished ? "checkmark.circle.fill" : "book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开书籍")
    }
}

struct BookCover: View {
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
            guard let url else { return }
            let uiImage = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return UIImage?.none }
                return UIImage(cgImage: thumbnail)
            }.value
            guard !Task.isCancelled, let uiImage else { return }
            image = Image(uiImage: uiImage)
        }
    }
}

#Preview { ContentView().environmentObject(LibraryStore()) }
