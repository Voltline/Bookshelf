import AVFoundation
import ReadiumNavigator
import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpeechSettingKeys.engine) private var engine = SpeechEngine.system.rawValue
    @AppStorage(SpeechSettingKeys.kokoroVoice) private var kokoroVoice = 3
    @AppStorage(SpeechSettingKeys.kokoroSpeed) private var kokoroSpeed = 1.0
    @ObservedObject private var modelStore = KokoroModelStore.shared
    @State private var previewTask: Task<Void, Never>?
    @State private var previewID = UUID()
    @State private var previewError: String?
    @State private var confirmDelete = false
    @AppStorage(SpeechSettingKeys.language) private var languageCode = "zh-CN"
    @AppStorage(SpeechSettingKeys.voiceIdentifier) private var voiceIdentifier = ""
    @AppStorage(SpeechSettingKeys.rate) private var rate = 0.5
    @AppStorage(SpeechSettingKeys.pitch) private var pitch = 1.0
    @AppStorage(SpeechSettingKeys.volume) private var volume = 1.0
    @AppStorage(SpeechSettingKeys.sentencePause) private var sentencePause = 0.0
    @AppStorage(SpeechSettingKeys.highlightEnabled) private var highlightEnabled = true
    @AppStorage(SpeechSettingKeys.autoPageTurnEnabled) private var autoPageTurnEnabled = true
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language == $1.language { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return localizedLanguage($0.language).localizedStandardCompare(localizedLanguage($1.language)) == .orderedAscending
        }
    }

    private var languages: [String] {
        Array(Set(voices.map(\.language))).sorted {
            localizedLanguage($0).localizedStandardCompare(localizedLanguage($1)) == .orderedAscending
        }
    }

    private var voicesForLanguage: [AVSpeechSynthesisVoice] {
        voices.filter { $0.language == languageCode }
    }

    private var selectedVoice: AVSpeechSynthesisVoice? {
        voices.first { $0.identifier == voiceIdentifier }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("声音") {
                    Picker("朗读引擎", selection: $engine) {
                        ForEach(SpeechEngine.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                    }
                    if engine == SpeechEngine.kokoro.rawValue {
                        Picker("离线音色", selection: $kokoroVoice) {
                            ForEach(Array(KokoroVoices.all.enumerated()), id: \.offset) { index, voice in
                                Text(voice.name).tag(index)
                            }
                        }
                    } else {
                        Picker("语言", selection: $languageCode) {
                            ForEach(languages, id: \.self) { code in
                                Text("\(localizedLanguage(code))（\(code)）").tag(code)
                            }
                        }
                        Picker("音色", selection: $voiceIdentifier) {
                            Text("系统默认").tag("")
                            ForEach(voicesForLanguage, id: \.identifier) { voice in
                                Text(voiceLabel(voice)).tag(voice.identifier)
                            }
                        }
                    }
                    Button {
                        previewVoice()
                    } label: {
                        Label(previewTask != nil || previewSynthesizer.isSpeaking ? "停止试听" : "试听声音", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(engine == SpeechEngine.kokoro.rawValue && (!modelStore.installed || modelStore.removing))
                }

                if engine == SpeechEngine.kokoro.rawValue {
                    Section {
                        LabeledContent("模型", value: "Kokoro 中文 v1.1 · INT8")
                        LabeledContent("状态", value: modelStore.installed ? "已下载 · 可离线使用" : "未下载完整模型")
                        if modelStore.removing {
                            ProgressView("正在释放并删除模型…")
                        } else if modelStore.downloading {
                            ProgressView(value: modelStore.progress)
                            Text("\(Int(modelStore.progress * 100))% · \(modelStore.status)").font(.caption).foregroundStyle(.secondary)
                            Button("取消下载", role: .cancel) { modelStore.cancel() }
                        } else if modelStore.installed {
                            Button("删除离线模型", role: .destructive) { confirmDelete = true }
                        } else {
                            Button("下载 / 继续下载模型（约 209 MB）") { modelStore.download() }
                            if modelStore.hasFiles {
                                Button("清除未完成下载", role: .destructive) { confirmDelete = true }
                            }
                            if !modelStore.status.isEmpty { Text(modelStore.status).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let error = modelStore.error { Text(error).font(.caption).foregroundStyle(.red) }
                        Link("模型来源与许可证", destination: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh")!)
                        NavigationLink("开源组件说明") {
                            List {
                                Text("本功能在本机使用 Kokoro 进行语音合成。以下组件许可独立适用；模型许可不替代运行库许可。")
                                Link("Kokoro 模型 · Apache-2.0", destination: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh")!)
                                Link("sherpa-onnx 1.13.8 · Apache-2.0", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8")!)
                                Link("ONNX Runtime · MIT", destination: URL(string: "https://github.com/microsoft/onnxruntime")!)
                                Link("eSpeak NG · GPL-3.0", destination: URL(string: "https://github.com/espeak-ng/espeak-ng")!)
                            }.navigationTitle("开源组件")
                        }
                    } header: { Text("离线模型") } footer: {
                        Text("首次下载需要网络，建议使用 Wi-Fi。下载完成后文字只在本机处理，无订阅或按字数收费。首次合成需要加载模型；暂停后从当前句子重新开始。此版本不提供逐字时间戳和音调调整。")
                    }
                }

                Section("朗读效果") {
                    if engine == SpeechEngine.kokoro.rawValue {
                        valueSlider("语速", value: $kokoroSpeed, range: 0.5 ... 2, step: 0.05, valueText: String(format: "%.2f×", kokoroSpeed))
                    } else {
                        valueSlider("语速", value: $rate, range: 0.35 ... 0.65, step: 0.01, valueText: String(format: "%.2f", rate))
                        valueSlider("音调", value: $pitch, range: 0.5 ... 2.0, step: 0.05, valueText: String(format: "%.2f", pitch))
                    }
                    valueSlider("音量", value: $volume, range: 0 ... 1, step: 0.05, valueText: "\(Int(volume * 100))%")
                    valueSlider("句间停顿", value: $sentencePause, range: 0 ... 1.5, step: 0.1, valueText: String(format: "%.1f 秒", sentencePause))
                }

                Section("阅读联动") {
                    Toggle("高亮正在朗读的句子", isOn: $highlightEnabled)
                    Toggle("朗读时自动翻页", isOn: $autoPageTurnEnabled)
                }

                if engine == SpeechEngine.system.rawValue, let voice = selectedVoice {
                    Section("当前音色信息") {
                        LabeledContent("名称", value: voice.name)
                        LabeledContent("语言", value: "\(localizedLanguage(voice.language))（\(voice.language)）")
                        LabeledContent("质量", value: qualityLabel(voice.quality))
                    }
                }

                Section {
                    Button("恢复朗读默认设置", role: .destructive) { restoreDefaults() }
                } footer: {
                    Text("系统朗读使用 iOS 音色；Kokoro 使用独立的本地模型，可随时切回系统朗读。恢复默认不会删除已下载模型。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onChange(of: languageCode) { _, _ in
                if selectedVoice?.language != languageCode { voiceIdentifier = "" }
            }
            .onChange(of: engine) { _, _ in stopPreview() }
            .onChange(of: kokoroVoice) { _, _ in stopPreview() }
            .onDisappear { stopPreview(); Task { await KokoroWorker.shared.unload() } }
            .alert("试听失败", isPresented: Binding(get: { previewError != nil }, set: { if !$0 { previewError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(previewError ?? "") }
            .confirmationDialog("删除 Kokoro 模型？之后可重新下载，不会删除书籍。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除模型", role: .destructive) {
                    stopPreview()
                    Task { await modelStore.remove() }
                }
            }
        }
    }

    @ViewBuilder
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: valueText)
            Slider(value: value, in: range, step: step)
        }
    }

    private func localizedLanguage(_ code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) · \(qualityLabel(voice.quality))"
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "高级"
        case .enhanced: "增强"
        default: "标准"
        }
    }

    private func previewVoice() {
        if previewTask != nil { stopPreview(); return }
        if engine == SpeechEngine.kokoro.rawValue {
            let id = UUID()
            previewID = id
            let settings = SpeechSettings(volume: volume, sentencePause: sentencePause,
                                          engine: .kokoro, kokoroVoice: kokoroVoice, kokoroSpeed: kokoroSpeed)
            previewTask = Task {
                defer {
                    if previewID == id {
                        previewTask = nil
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    }
                }
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    try await KokoroTTSEngine(settings: settings).play(text: "欢迎使用书架离线朗读。窗外的风轻轻吹过，故事正要开始。", voice: settings.kokoroVoice)
                } catch is CancellationError {} catch { if !Task.isCancelled { previewError = error.localizedDescription } }
            }
            return
        }
        if previewSynthesizer.isSpeaking {
            previewSynthesizer.stopSpeaking(at: .immediate)
            return
        }
        let sample = languageCode.hasPrefix("zh") ? "欢迎使用书架语音朗读。" : "Welcome to Bookshelf text to speech."
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = voiceIdentifier.isEmpty
            ? AVSpeechSynthesisVoice(language: languageCode)
            : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = Float(volume)
        utterance.preUtteranceDelay = sentencePause
        previewSynthesizer.speak(utterance)
    }

    private func restoreDefaults() {
        stopPreview()
        engine = SpeechEngine.system.rawValue
        kokoroVoice = 3
        kokoroSpeed = 1.0
        languageCode = "zh-CN"
        voiceIdentifier = ""
        rate = 0.5
        pitch = 1.0
        volume = 1.0
        sentencePause = 0
        highlightEnabled = true
        autoPageTurnEnabled = true
    }

    private func stopPreview() {
        previewSynthesizer.stopSpeaking(at: .immediate)
        previewTask?.cancel()
        previewTask = nil
        previewID = UUID()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
