import AVFoundation
import Foundation
@preconcurrency import ReadiumNavigator
import ReadiumShared
import SherpaOnnx

enum KokoroVoices {
    // Official v1.1 mapping: 0...2 English, 3...57 Chinese female, 58...102 Chinese male.
    static let all: [TTSVoice] = (0...102).map { id in
        let name = id < 3 ? ["Maple · 美式女声", "Sol · 美式女声", "Vale · 英式女声"][id]
            : id < 58 ? "中文女声 \(id - 2)" : "中文男声 \(id - 57)"
        return TTSVoice(identifier: "kokoro.\(id)", language: Language(code: .bcp47(id < 3 ? (id == 2 ? "en-GB" : "en-US") : "zh-CN")),
                        name: name, gender: id < 58 ? .female : .male, quality: nil)
    }
}

/// A C callback can check cancellation even while the actor is busy generating audio.
private nonisolated final class KokoroCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

actor KokoroWorker {
    static let shared = KokoroWorker()
    private var synthesizer: SherpaOnnxOfflineTtsWrapper?

    func unload() { synthesizer = nil }

    private func load() throws -> SherpaOnnxOfflineTtsWrapper {
        if let synthesizer { return synthesizer }
        guard KokoroModel.isInstalled else { throw KokoroError.message("请先到书架的设置页下载 Kokoro 离线模型") }
        let directory = KokoroModel.directory
        // Keep the NSString-backed configuration pointers alive until C has copied them.
        return try autoreleasepool {
            func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: path("model.int8.onnx"), voices: path("voices.bin"), tokens: path("tokens.txt"),
                dataDir: path("espeak-ng-data"), dictDir: path("dict"),
                lexicon: path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt")
            )
            let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2, provider: "cpu")
            var config = sherpaOnnxOfflineTtsConfig(model: model,
                ruleFsts: ["date-zh.fst", "number-zh.fst", "phone-zh.fst"].map(path).joined(separator: ","))
            let engine = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard engine.tts != nil else { throw KokoroError.message("Kokoro 模型加载失败，请重新下载模型") }
            synthesizer = engine
            return engine
        }
    }

    func render(text: String, voice: Int, speed: Float) async throws -> URL {
        let cancellation = KokoroCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let engine = try load()
            try Task.checkCancellation()
            guard (0..<Int(engine.numSpeakers)).contains(voice) else { throw KokoroError.message("无效的 Kokoro 音色") }
            let pointer = Unmanaged.passUnretained(cancellation).toOpaque()
            let audio = engine.generateWithCallbackWithArg(text: text, callback: { _, _, raw in
                guard let raw else { return 0 }
                return Unmanaged<KokoroCancellation>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 0 : 1
            }, arg: pointer, sid: voice, speed: speed)
            try Task.checkCancellation()
            guard audio.audio != nil, audio.n > 0 else { throw KokoroError.message("Kokoro 未能生成这段文字的声音") }
            let url = URL.temporaryDirectory.appendingPathComponent("kokoro-\(UUID().uuidString).wav")
            guard audio.save(filename: url.path) == 1 else { throw KokoroError.message("无法缓存朗读音频") }
            return url
        } onCancel: { cancellation.cancel() }
    }
}

final class KokoroTTSEngine: TTSEngine {
    let availableVoices = KokoroVoices.all
    private let settings: SpeechSettings

    init(settings: SpeechSettings) { self.settings = settings }

    func speak(_ utterance: TTSUtterance, onSpeakRange: @escaping (Range<String.Index>) -> Void) async -> Result<Void, TTSError> {
        let id: Int
        switch utterance.voiceOrLanguage {
        case .left(let voice): id = Int(voice.identifier.replacingOccurrences(of: "kokoro.", with: "")) ?? settings.kokoroVoice
        case .right: id = settings.kokoroVoice
        }
        do {
            try await play(text: utterance.text, voice: id, delay: utterance.delay, onSpeakRange: onSpeakRange)
            return .success(())
        } catch { return .failure(.other(error)) }
    }

    /// Also used by the settings preview, so preview exercises the exact same synthesis path.
    func play(text: String, voice: Int, delay: Double = 0,
              onSpeakRange: @escaping (Range<String.Index>) -> Void = { _ in }) async throws {
        if delay + settings.sentencePause > 0 {
            try await Task.sleep(for: .seconds(max(0, delay + settings.sentencePause)))
        }
        // Bound input size: long unpunctuated EPUB paragraphs must not overflow the model's token limit.
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            let limit = text.index(start, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            // Prefer a natural boundary within a long sentence instead of splitting a word.
            let end: String.Index
            if limit < text.endIndex,
               let boundary = text[start..<limit].lastIndex(where: { "，。！？；,.!?; \n".contains($0) }) {
                end = text.index(after: boundary)
            } else { end = limit }
            let chunk = String(text[start..<end])
            // Chapter separators such as “……” have nothing to pronounce.
            if chunk.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                let url = try await KokoroWorker.shared.render(text: chunk, voice: voice, speed: Float(min(2, max(0.5, settings.kokoroSpeed))))
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = Float(settings.volume)
                player.prepareToPlay()
                guard player.play() else { throw KokoroError.message("无法播放离线朗读音频") }
                defer { player.stop() }
                onSpeakRange(start..<end)
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(30))
                }
                try Task.checkCancellation()
            }
            start = end
        }
    }
}
