import SwiftUI
import UniformTypeIdentifiers
import ReadiumShared

enum AnnotationExportFormat: String, CaseIterable, Identifiable {
    case markdown, text
    var id: String { rawValue }
    var name: String { self == .markdown ? "Markdown" : "纯文本" }
    var contentType: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText }
}

struct AnnotationExport {
    let text: String
    let bookCount: Int
    let markCount: Int
}

enum ReaderAnnotationExporter {
    static func make(books: [Book], marks: (UUID) -> [ReaderMark], format: AnnotationExportFormat, date: Date) -> AnnotationExport {
        let markdown = format == .markdown
        var lines = [markdown ? "# 划线与笔记" : "划线与笔记", "", "导出时间：\(date.formatted(date: .abbreviated, time: .shortened))", ""]
        var bookCount = 0, markCount = 0
        for book in books {
            // Decode each locator once, not on every O(n log n) comparison.
            let highlights = marks(book.id).filter { $0.kind == .highlight }.map { mark in
                let location = mark.locator?.locations
                return (mark: mark, position: location?.position ?? Int.max, progress: location?.totalProgression ?? 1)
            }.sorted { left, right in
                if left.position != right.position { return left.position < right.position }
                if left.progress != right.progress { return left.progress < right.progress }
                let left = left.mark, right = right.mark
                if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                return left.id.uuidString < right.id.uuidString
            }.map(\.mark)
            guard !highlights.isEmpty else { continue }
            bookCount += 1; markCount += highlights.count
            lines += [markdown ? "## \(escape(book.title))" : "《\(book.title)》", "", "作者：\(markdown ? escape(book.author) : book.author)", ""]
            var previousChapter: String?
            for mark in highlights {
                let chapter = mark.chapter.isEmpty ? "正文" : mark.chapter
                if chapter != previousChapter {
                    lines += [markdown ? "### \(escape(chapter))" : "【\(chapter)】", ""]
                    previousChapter = chapter
                }
                if markdown {
                    lines += mark.excerpt.components(separatedBy: .newlines).map { "> \(escape($0))" }
                    if !mark.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines += ["", "笔记："] + mark.note.components(separatedBy: .newlines).map { escape($0) }
                    }
                } else {
                    lines += ["划线：", mark.excerpt]
                    if !mark.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines += ["", "笔记：", mark.note] }
                }
                lines += ["", "标注于 \(mark.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(mark.color.name)", "", "---", ""]
            }
        }
        return .init(text: lines.joined(separator: "\n"), bookCount: bookCount, markCount: markCount)
    }

    private static func escape(_ string: String) -> String {
        var result = string.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "+", "-", "!", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

struct AnnotationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, UTType(filenameExtension: "md") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct AnnotationExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    var bookID: UUID?
    @State private var format: AnnotationExportFormat = .markdown
    @State private var date = Date()
    @State private var showExporter = false
    @State private var exportError: String?

    private var books: [Book] { library.books.filter { bookID == nil || $0.id == bookID } }
    private var export: AnnotationExport {
        ReaderAnnotationExporter.make(books: books, marks: library.readerMarks, format: format, date: date)
    }
    private var fileName: String {
        let title = bookID == nil ? "书架" : (books.first?.title ?? "书籍")
        return String(title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/:\\".unicodeScalars.contains($0) ? "_" : String($0) }.joined().prefix(80)) + "-划线与笔记"
    }

    var body: some View {
        let output = export
        NavigationStack {
            Form {
                Section {
                    LabeledContent("范围", value: bookID == nil ? "全部书籍（不含最近删除）" : (books.first?.title ?? "书籍"))
                    LabeledContent("标注", value: "\(output.bookCount) 本书 · \(output.markCount) 条划线")
                    Picker("导出格式", selection: $format) {
                        ForEach(AnnotationExportFormat.allCases) { Text($0.name).tag($0) }
                    }
                } footer: { Text("仅导出你保存的划线和笔记，不包含完整书籍正文。") }

                Section {
                    NavigationLink("预览内容") {
                        ScrollView {
                            Text(output.text).font(.body.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }.navigationTitle("导出预览").navigationBarTitleDisplayMode(.inline)
                    }
                    Button("存储到文件", systemImage: "square.and.arrow.down") { showExporter = true }
                    ShareLink(item: output.text) { Label("分享文本", systemImage: "square.and.arrow.up") }
                }.disabled(output.markCount == 0)

                if output.markCount == 0 {
                    Section { Text("还没有可导出的标注。阅读时长按正文选中文字，即可保存划线并添加笔记。") .foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("导出划线与笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $showExporter, document: AnnotationDocument(text: output.text), contentType: format.contentType, defaultFilename: fileName) { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("好", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "请重试。") }
        }
    }
}
