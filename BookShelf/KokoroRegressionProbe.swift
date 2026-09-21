#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// Explicit simulator-only smoke test. No user library content is used.
struct KokoroRegressionProbe: View {
    @ObservedObject private var store = KokoroModelStore.shared
    @State private var status = "正在检查模型"
    @State private var reader: ReadiumReaderModel?
    var body: some View {
        VStack {
            Text(status)
            ProgressView(value: store.progress)
            Text(store.status).font(.caption)
            if let navigator = reader?.navigator { KokoroProbeNavigator(navigator: navigator) }
        }.padding().task {
            @MainActor func report(_ message: String) {
                status = message
                try? message.write(to: URL.documentsDirectory.appendingPathComponent("kokoro-results.txt"), atomically: true, encoding: .utf8)
            }
            do {
                let existingModel = store.installed
                if !store.installed {
                    store.download()
                    while store.downloading {
                        report("DOWNLOAD \(Int(store.progress * 100))% \(store.status)")
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                guard store.installed else { throw KokoroError.message(store.error ?? "模型安装失败") }
                report("SYNTHESIS")
                let start = Date()
                let audio = try await KokoroWorker.shared.render(text: "窗外的风轻轻吹过，故事正要开始。", voice: 3, speed: 1)
                defer { try? FileManager.default.removeItem(at: audio) }
                let file = try AVAudioFile(forReading: audio)
                guard file.length > 2400 else { throw KokoroError.message("音频过短") }
                let output = URL.documentsDirectory.appendingPathComponent("kokoro-sample.wav")
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.copyItem(at: audio, to: output)
                let seconds = Date().timeIntervalSince(start)
                report("PLAYBACK")
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let engine = KokoroTTSEngine(settings: SpeechSettings(engine: .kokoro))
                var ranges = 0
                try await engine.play(text: "这是离线试听。", voice: 58) { _ in ranges += 1 }
                guard ranges > 0 else { throw KokoroError.message("没有朗读范围回调") }
                let task = Task { try await engine.play(text: String(repeating: "这是取消合成测试。", count: 20), voice: 3) }
                try await Task.sleep(for: .milliseconds(200))
                task.cancel()
                do { try await task.value; throw KokoroError.message("取消未生效") } catch is CancellationError {}
                await KokoroWorker.shared.unload()
                let fixture = URL.documentsDirectory.appendingPathComponent("font-test.epub")
                guard FileManager.default.fileExists(atPath: fixture.path) else { throw KokoroError.message("请把 Tests/FontRegression/font-test.epub 拷贝到模拟器 Documents 后运行") }
                report("READIUM")
                let library = LibraryStore()
                guard let book = await library.importBook(from: fixture) else { throw KokoroError.message(library.errorMessage ?? "EPUB 导入失败") }
                defer { library.delete(book) }
                let model = ReadiumReaderModel(book: book, store: library)
                await model.load(fontSize: 20, lineSpacing: 8, mode: .page, theme: .paper, font: .publisher,
                                 speechSettings: SpeechSettings(engine: .kokoro))
                reader = model
                for _ in 0..<100 {
                    if model.isNavigatorReady { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard model.isNavigatorReady else { throw KokoroError.message(model.errorMessage ?? "阅读页未就绪") }
                model.toggleSpeech()
                var advanced = false
                for _ in 0..<600 {
                    if let error = model.errorMessage { throw KokoroError.message(error) }
                    if model.navigator?.currentLocation?.href.string.contains("chapter2.xhtml") == true {
                        advanced = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                model.stopSpeech()
                guard advanced else { throw KokoroError.message("朗读没有自动进入第二章") }
                report("PASS: \(existingModel ? "offline cached model" : "downloaded and verified model"); Chinese female synthesis \(file.length) frames / \(file.processingFormat.sampleRate) Hz in \(seconds)s; male playback + highlight callback; cancellation; Readium speech automatically advanced to chapter 2. Sample: kokoro-sample.wav")
            } catch { report("FAIL: \(error)") }
        }
    }
}

private struct KokoroProbeNavigator: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
#endif
