import SwiftUI

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    let book: Book
    let onRead: (Book) -> Void
    @State private var title: String
    @State private var author: String
    @State private var isFavorite: Bool
    @State private var isFinished: Bool
    @State private var showExport = false

    init(book: Book, library: LibraryStore, onRead: @escaping (Book) -> Void) {
        self.book = book
        self.library = library
        self.onRead = onRead
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _isFavorite = State(initialValue: book.isFavorite)
        _isFinished = State(initialValue: book.isFinished)
    }

    private var currentBook: Book { library.books.first(where: { $0.id == book.id }) ?? book }
    private var validTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        BookCover(title: currentBook.title, url: library.coverURL(for: currentBook))
                            .frame(width: 100, height: 146)
                            .clipShape(.rect(cornerRadius: 8))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    Button {
                        if saveDetails() { onRead(currentBook) }
                    } label: {
                        Label(currentBook.hasStartedReading ? "继续阅读" : "开始阅读", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .disabled(!validTitle)
                }

                Section {
                    TextField("书名", text: $title, axis: .vertical)
                        .accessibilityLabel("书名")
                    TextField("作者", text: $author)
                        .accessibilityLabel("作者")
                } header: { Text("书籍信息") } footer: { Text("修改书名与作者只影响书架显示。") }

                Section("整理") {
                    Toggle("收藏", isOn: $isFavorite)
                    Toggle("已读完", isOn: $isFinished)
                    LabeledContent("阅读进度", value: currentBook.hasStartedReading ? "已读 \(Int((currentBook.locator.fraction * 100).rounded()))%" : "未开始")
                    if !currentBook.collectionIDs.isEmpty {
                        LabeledContent("书单", value: library.collections.filter { currentBook.collectionIDs.contains($0.id) }.map(\.name).joined(separator: "、"))
                    }
                }

                Section("划线与笔记") {
                    LabeledContent("已保存", value: "\(library.readerMarks(for: book.id).count) 条划线")
                    Button("导出划线与笔记", systemImage: "square.and.arrow.up") { showExport = true }
                        .disabled(library.readerMarks(for: book.id).isEmpty)
                }

                Section("阅读记录") {
                    BookActivitySummary(activity: library.activity, bookID: book.id)
                }

                Section("文件") {
                    LabeledContent("格式", value: currentBook.sourceFormat ?? "EPUB")
                    if let size = library.fileSize(for: currentBook) {
                        LabeledContent("本地大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    LabeledContent("导入时间", value: currentBook.importedAt.formatted(date: .abbreviated, time: .omitted))
                    if let opened = currentBook.lastOpenedAt {
                        LabeledContent("最近阅读", value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showExport) { AnnotationExportView(library: library, bookID: book.id) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if saveDetails() { dismiss() } }.disabled(!validTitle)
                }
            }
            .alert("无法保存", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好", role: .cancel) { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "请重试。") }
        }
    }

    private func saveDetails() -> Bool {
        if title == currentBook.title && author == currentBook.author && isFavorite == currentBook.isFavorite && isFinished == currentBook.isFinished { return true }
        return library.editBook(bookID: book.id, title: title, author: author, isFavorite: isFavorite, isFinished: isFinished)
    }
}

struct BookImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: BookImportReport

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !report.imported.isEmpty { Label("成功导入 \(report.imported.count) 本", systemImage: "checkmark.circle") }
                    if !report.restored.isEmpty { Label("恢复 \(report.restored.count) 本", systemImage: "arrow.uturn.backward.circle") }
                    if !report.skipped.isEmpty { Label("跳过 \(report.skipped.count) 个重复文件", systemImage: "doc.on.doc") }
                    if report.cancelledFileCount > 0 { Label("已停止，\(report.cancelledFileCount) 个文件未处理", systemImage: "stop.circle") }
                    if !report.failures.isEmpty {
                        Label("\(report.failures.count) 个文件未导入", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !report.restored.isEmpty {
                    Section {
                        ForEach(report.restored) { book in
                            Label(book.title, systemImage: "arrow.uturn.backward")
                        }
                    } header: { Text("已从最近删除恢复") } footer: { Text("相同文件不重复入库，原有阅读进度、书单和笔记均已保留。") }
                }
                if !report.skipped.isEmpty {
                    Section {
                        ForEach(report.skipped) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.fileName).font(.subheadline.weight(.medium))
                                Text("书架中已有《\(item.book.title)》") .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("已跳过重复文件") } footer: { Text("按文件内容识别，不会因为书名相同就跳过不同版本。") }
                }
                if !report.imported.isEmpty {
                    Section("已添加到书架") {
                        ForEach(report.imported) { book in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title)
                                Text(book.author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !report.failures.isEmpty {
                    Section("未导入的文件") {
                        ForEach(report.failures) { failure in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(failure.fileName).font(.subheadline.weight(.medium))
                                Text(failure.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
