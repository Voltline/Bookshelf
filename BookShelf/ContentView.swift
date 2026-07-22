import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let epub = UTType(filenameExtension: "epub") ?? .data
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var isImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var pendingDeletion: Book?

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return library.books }
        return library.books.filter { $0.title.localizedStandardContains(searchText) || $0.author.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty { emptyLibrary }
                else { bookGrid }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { isSettingsPresented = true } label: { Label("设置", systemImage: "gearshape") }
                    Button { isImporterPresented = true } label: { Label("导入 EPUB", systemImage: "plus") }
                        .disabled(library.isImporting)
                }
            }
            .searchable(text: $searchText, prompt: "搜索书名或作者")
            .navigationDestination(for: Book.self) { book in ReaderView(book: book, library: library) }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.epub], allowsMultipleSelection: false) { result in
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

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 24)], spacing: 28) {
                ForEach(filteredBooks) { book in
                    NavigationLink(value: book) { BookTile(book: book, coverURL: library.coverURL(for: book)) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { pendingDeletion = book } label: { Label("删除", systemImage: "trash") }
                        }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .overlay {
            if filteredBooks.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("书架是空的", systemImage: "books.vertical")
        } description: {
            Text("导入一本 EPUB，开始阅读或聆听。")
        } actions: {
            Button { isImporterPresented = true } label: { Label("导入 EPUB", systemImage: "square.and.arrow.down") }
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

private struct BookTile: View {
    let book: Book
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCover(title: book.title, url: coverURL)
                .aspectRatio(0.68, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.15), radius: 7, y: 4)
                .overlay(alignment: .bottomLeading) {
                    if book.locator.totalPages > 0 {
                        ProgressView(value: book.locator.fraction)
                            .tint(.white).padding(8)
                    }
                }
            Text(book.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
            Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if book.locator.page > 0 { Text("已读 \(Int(book.locator.fraction * 100))%") .font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(book.locator.page > 0 ? "继续阅读" : "开始阅读")
    }
}

private struct BookCover: View {
    let title: String
    let url: URL?
    @State private var image: Image?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.9), .blue.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { image.resizable().scaledToFill() }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "book.closed.fill").font(.title).foregroundStyle(.white.opacity(0.75))
                    Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(4).foregroundStyle(.white).padding(.horizontal, 12)
                }
            }
        }
        .task(id: url) {
            guard let url, let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) else { return }
            image = Image(uiImage: uiImage)
        }
    }
}

#Preview { ContentView().environmentObject(LibraryStore()) }
