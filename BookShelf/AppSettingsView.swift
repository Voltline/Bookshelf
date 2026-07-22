import AVFoundation
import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
                    Button {
                        previewVoice()
                    } label: {
                        Label(previewSynthesizer.isSpeaking ? "停止试听" : "试听声音", systemImage: "speaker.wave.2.fill")
                    }
                }

                Section("朗读效果") {
                    valueSlider("语速", value: $rate, range: 0.35 ... 0.65, step: 0.01, valueText: String(format: "%.2f", rate))
                    valueSlider("音调", value: $pitch, range: 0.5 ... 2.0, step: 0.05, valueText: String(format: "%.2f", pitch))
                    valueSlider("音量", value: $volume, range: 0 ... 1, step: 0.05, valueText: "\(Int(volume * 100))%")
                    valueSlider("句间停顿", value: $sentencePause, range: 0 ... 1.5, step: 0.1, valueText: String(format: "%.1f 秒", sentencePause))
                }

                Section("阅读联动") {
                    Toggle("高亮正在朗读的句子", isOn: $highlightEnabled)
                    Toggle("朗读时自动翻页", isOn: $autoPageTurnEnabled)
                }

                if let voice = selectedVoice {
                    Section("当前音色信息") {
                        LabeledContent("名称", value: voice.name)
                        LabeledContent("语言", value: "\(localizedLanguage(voice.language))（\(voice.language)）")
                        LabeledContent("质量", value: qualityLabel(voice.quality))
                    }
                }

                Section {
                    Button("恢复朗读默认设置", role: .destructive) { restoreDefaults() }
                } footer: {
                    Text("可选音色由 iOS 提供；在系统设置中下载的增强音色也会显示在这里。")
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
        previewSynthesizer.stopSpeaking(at: .immediate)
        languageCode = "zh-CN"
        voiceIdentifier = ""
        rate = 0.5
        pitch = 1.0
        volume = 1.0
        sentencePause = 0
        highlightEnabled = true
        autoPageTurnEnabled = true
    }
}
