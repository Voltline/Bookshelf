#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import WebKit
import ReadiumNavigator

struct FontRegressionProbe: View {
    @State private var model: ReadiumReaderModel?
    var body: some View {
        VStack {
            if let navigator = model?.navigator { ProbeController(controller: navigator) }
            else { Text("Font regression test") }
        }.task {
            var results: [String] = []
            var samples: [String: [Int]] = [:]
            do {
                let library = LibraryStore()
                guard let book = await library.importBook(from: .documentsDirectory.appendingPathComponent("font-test.epub")) else {
                    throw NSError(domain: library.errorMessage ?? "import", code: 1)
                }
                defer { library.delete(book) }
                let reader = ReadiumReaderModel(book: book, store: library)
                await reader.load(fontSize: 20, lineSpacing: 8, mode: .page, theme: .paper, font: .publisher, speechSettings: .init())
                model = reader
                guard let nav = reader.navigator else { throw NSError(domain: reader.errorMessage ?? "load", code: 2) }
                for _ in 0..<100 {
                    if reader.isNavigatorReady { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard reader.isNavigatorReady else { throw NSError(domain: "Navigator did not become ready", code: 3) }
                func webViews(_ view: UIView) -> [WKWebView] {
                    if let web = view as? WKWebView { return [web] }
                    return view.subviews.flatMap(webViews)
                }
                for font in [ReadingFont.publisher, .sansSerif, .serif, .kai, .monospace, .publisher] {
                    reader.applyPreferences(fontSize: 20, lineSpacing: 8, mode: .page, theme: .paper, font: font)
                    try await Task.sleep(for: .seconds(1))
                    for web in webViews(nav.view) {
                        let result = try await web.callAsyncJavaScript(#"""
                        const sample = document.getElementById('sample');
                        if (!sample) return 'no sample';
                        const family = getComputedStyle(sample).fontFamily;
                        await document.fonts.load('24px ' + family, sample.textContent);
                        await document.fonts.ready;
                        const canvas = document.createElement('canvas');
                        canvas.width = 1100; canvas.height = 80;
                        const ctx = canvas.getContext('2d');
                        ctx.font = '24px ' + family;
                        ctx.fillText('春江潮水连海平海上明月共潮生阅读字体测试', 0, 40);
                        const data = ctx.getImageData(0, 0, 1100, 80).data;
                        let hash = 0;
                        for (const n of data) hash = ((hash * 31) + n) | 0;
                        return JSON.stringify({family, hash, chapter: location.pathname});
                        """#, arguments: [:], in: nil, contentWorld: .page)
                        results.append("\(font.rawValue): \(result ?? "nil")")
                        if let json = result as? String, let data = json.data(using: .utf8),
                           let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let chapter = value["chapter"] as? String, let hash = value["hash"] as? Int {
                            samples[chapter, default: []].append(hash)
                        }
                    }
                }
                guard samples.count == 2, samples.values.allSatisfy({
                    $0.count == 6 && $0[0] == $0[1] && $0[1] != $0[2] && $0[0] == $0[5]
                }) else { throw NSError(domain: "CJK font change/restoration regression", code: 4) }
                results.append("PASS: both chapters change CJK glyphs and restore publisher fonts")
            } catch { results.append("ERROR: \(error)") }
            try? results.joined(separator: "\n").write(to: URL.documentsDirectory.appendingPathComponent("font-results.txt"), atomically: true, encoding: .utf8)
        }
    }
}
private struct ProbeController: UIViewControllerRepresentable {
    let controller: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { controller }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
#endif
