#if DEBUG && targetEnvironment(simulator)
import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// Verifies TXT conversion, Readium search locators and opening a hit in the navigator.
struct FullTextRegressionProbe: View {
    @State private var reader: ReadiumReaderModel?

    var body: some View {
        Group {
            if let navigator = reader?.navigator {
                SearchProbeNavigator(navigator: navigator)
            } else {
                ProgressView("正在验证全文搜索…")
            }
        }
        .task { await run() }
    }

    private func run() async {
        var report: [String] = []
        let library = LibraryStore()
        let source = URL.documentsDirectory.appendingPathComponent("fulltext-probe-\(UUID().uuidString).txt")
        do {
            try "第一章 开始\n蓝鲸在海面上游过。\n第二章 继续\n这里又出现一只蓝鲸。".write(
                to: source, atomically: true, encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: source) }
            guard let book = await library.importBook(from: source) else {
                throw NSError(domain: library.errorMessage ?? "TXT import failed", code: 1)
            }
            defer { library.delete(book) }
            let publication = try await library.publication(for: book)
            var hits: [BookSearchMatch] = []
            let truncated = try await FullTextSearch.search(publication: publication, query: "蓝鲸", limit: 10) {
                hits.append(contentsOf: $0)
            }
            guard hits.count == 2, !truncated,
                  hits.allSatisfy({ $0.locator.text.highlight == "蓝鲸" }) else {
                throw NSError(domain: "TXT search returned \(hits.count) matches", code: 2)
            }
            report.append("TXT: 2 matches with text snippets and locators")

            let target = hits[1].locator
            let model = ReadiumReaderModel(book: book, store: library, initialSearchLocator: target)
            await model.load(fontSize: 20, lineSpacing: 8, mode: .page, theme: .paper, font: .serif, speechSettings: .init())
            reader = model
            for _ in 0..<100 {
                if model.isNavigatorReady { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard model.isNavigatorReady,
                  model.navigator?.currentLocation?.href.isEquivalentTo(target.href) == true else {
                throw NSError(domain: "Search locator did not open in the navigator", code: 3)
            }
            report.append("Navigator: opened the selected search hit")

            let epubFixture = URL.documentsDirectory.appendingPathComponent("fulltext-sample.epub")
            if FileManager.default.fileExists(atPath: epubFixture.path) {
                guard let epubBook = await library.importBook(from: epubFixture) else {
                    throw NSError(domain: library.errorMessage ?? "EPUB import failed", code: 4)
                }
                defer { library.delete(epubBook) }
                let epub = try await library.publication(for: epubBook)
                var epubHits: [BookSearchMatch] = []
                _ = try await FullTextSearch.search(publication: epub, query: "春江潮水", limit: 10) {
                    epubHits.append(contentsOf: $0)
                }
                guard !epubHits.isEmpty else { throw NSError(domain: "EPUB search found no sample matches", code: 5) }
                report.append("EPUB: found \(epubHits.count) sample matches")
            }
            report.append("PASS")
        } catch {
            report.append("ERROR: \(error)")
        }
        try? report.joined(separator: "\n").write(
            to: URL.documentsDirectory.appendingPathComponent("fulltext-results.txt"),
            atomically: true, encoding: .utf8
        )
    }
}

private struct SearchProbeNavigator: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
#endif
