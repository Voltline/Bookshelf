#if DEBUG && targetEnvironment(simulator)
import CoreFoundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// Exercises real TXT import, Readium parsing and navigator display on iOS.
struct TXTRegressionProbe: View {
    @State private var reader: ReadiumReaderModel?

    var body: some View {
        Group {
            if let navigator = reader?.navigator {
                TXTProbeNavigator(navigator: navigator)
            } else {
                ProgressView("正在验证 TXT 导入…")
            }
        }
        .task { await run() }
    }

    private func run() async {
        var results: [String] = []
        let library = LibraryStore()
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))
        let longChapter = String(repeating: "春江潮水连海平，海上明月共潮生。\n", count: 4_000)
        let text = "第一章 开始\n\(longChapter)\n第二章 结尾\n文字 & <标签> 仍可阅读。"
        let cases: [(String, String.Encoding)] = [
            ("utf8", .utf8), ("utf16", .utf16), ("gb18030", gb18030),
        ]
        do {
            for (name, encoding) in cases {
                let source = URL.documentsDirectory.appendingPathComponent("txt-regression-\(UUID().uuidString).txt")
                guard let data = text.data(using: encoding) else {
                    throw NSError(domain: "Cannot encode \(name) fixture", code: 1)
                }
                try data.write(to: source)
                defer { try? FileManager.default.removeItem(at: source) }
                guard let book = await library.importBook(from: source) else {
                    throw NSError(domain: library.errorMessage ?? "Import failed: \(name)", code: 2)
                }
                defer { library.delete(book) }

                let publication = try await library.publication(for: book)
                let toc = try await publication.tableOfContents().get()
                guard publication.readingOrder.count >= 3,
                      toc.map(\.title) == ["第一章 开始", "第二章 结尾"] else {
                    throw NSError(domain: "Missing chapter split or TOC: \(name)", code: 3)
                }
                results.append("\(name): \(publication.readingOrder.count) reading-order items, \(toc.count) chapters")

                if name == "utf8" {
                    let model = ReadiumReaderModel(book: book, store: library)
                    await model.load(fontSize: 20, lineSpacing: 8, mode: .page, theme: .paper, font: .serif, speechSettings: .init())
                    reader = model
                    for _ in 0..<100 {
                        if model.isNavigatorReady { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    guard model.isNavigatorReady else { throw NSError(domain: "TXT navigator did not load", code: 4) }
                }
            }
            results.append("PASS: UTF-8, UTF-16 and GB18030 TXT imported with chapters; Readium navigator loaded")
        } catch {
            results.append("ERROR: \(error)")
        }
        try? results.joined(separator: "\n").write(
            to: URL.documentsDirectory.appendingPathComponent("txt-results.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private struct TXTProbeNavigator: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
#endif
