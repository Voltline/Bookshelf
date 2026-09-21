import ReadiumNavigator
import ReadiumShared
import SwiftUI

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReadiumReaderModel
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var theme = ReadingTheme.paper.rawValue
    @AppStorage("reader.mode") private var mode = ReadingMode.page.rawValue
    @AppStorage("reader.font") private var font = ReadingFont.publisher.rawValue
    @AppStorage(SpeechSettingKeys.language) private var speechLanguage = "zh-CN"
    @AppStorage(SpeechSettingKeys.engine) private var speechEngine = SpeechEngine.system.rawValue
    @AppStorage(SpeechSettingKeys.kokoroVoice) private var kokoroVoice = 3
    @AppStorage(SpeechSettingKeys.kokoroSpeed) private var kokoroSpeed = 1.0
    @AppStorage(SpeechSettingKeys.voiceIdentifier) private var speechVoiceIdentifier = ""
    @AppStorage(SpeechSettingKeys.rate) private var speechRate = 0.5
    @AppStorage(SpeechSettingKeys.pitch) private var speechPitch = 1.0
    @AppStorage(SpeechSettingKeys.volume) private var speechVolume = 1.0
    @AppStorage(SpeechSettingKeys.sentencePause) private var speechSentencePause = 0.0
    @AppStorage(SpeechSettingKeys.highlightEnabled) private var speechHighlightEnabled = true
    @AppStorage(SpeechSettingKeys.autoPageTurnEnabled) private var speechAutoPageTurnEnabled = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var sliderProgress = 0.0
    @State private var isScrubbingProgress = false

    init(book: Book, library: LibraryStore) {
        _model = StateObject(wrappedValue: ReadiumReaderModel(book: book, store: library))
    }

    private var readingTheme: ReadingTheme { ReadingTheme(rawValue: theme) ?? .paper }
    private var readingMode: ReadingMode { ReadingMode(rawValue: mode) ?? .page }
    private var readingFont: ReadingFont { ReadingFont(rawValue: font) ?? .publisher }

    private func applyReadingPreferences() {
        model.applyPreferences(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            mode: readingMode,
            theme: readingTheme,
            font: readingFont
        )
    }

    private var speechSettings: SpeechSettings {
        SpeechSettings(
            languageCode: speechLanguage,
            voiceIdentifier: speechVoiceIdentifier,
            rate: speechRate,
            pitch: speechPitch,
            volume: speechVolume,
            sentencePause: speechSentencePause,
            highlightEnabled: speechHighlightEnabled,
            autoPageTurnEnabled: speechAutoPageTurnEnabled,
            engine: SpeechEngine(rawValue: speechEngine) ?? .system,
            kokoroVoice: kokoroVoice,
            kokoroSpeed: kokoroSpeed
        )
    }

    var body: some View {
        ZStack {
            if let navigator = model.navigator {
                EPUBNavigatorContainer(navigator: navigator)
                    .ignoresSafeArea()
                if !model.isNavigatorReady {
                    ProgressView("正在载入正文…")
                        .padding(18)
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                        .allowsHitTesting(false)
                }
            } else if model.isLoading {
                ProgressView("正在打开…")
            } else {
                ContentUnavailableView("无法打开书籍", systemImage: "exclamationmark.triangle", description: Text(model.errorMessage ?? "未知错误"))
            }

            if model.controlsVisible, model.navigator != nil {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(model.controlsVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(readingTheme == .night ? .dark : .light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("返回书架")
            }
            ToolbarItem(placement: .principal) {
                Text(model.book.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showChapters = true } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("目录")
                Button { showSettings = true } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("阅读设置")
            }
        }
        .statusBarHidden(!model.controlsVisible)
        .animation(.easeInOut(duration: 0.18), value: model.controlsVisible)
        .task {
            if !ReaderFonts.available.contains(readingFont) {
                font = (ReaderFonts.available.contains(.serif) ? ReadingFont.serif : .sansSerif).rawValue
            }
            await model.load(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                mode: readingMode,
                theme: readingTheme,
                font: readingFont,
                speechSettings: speechSettings
            )
        }
        .onChange(of: model.progression) { _, value in
            if !isScrubbingProgress {
                sliderProgress = value
            }
        }
        .onDisappear { model.stopSpeech() }
        .onChange(of: font) { _, _ in applyReadingPreferences() }
        .sheet(isPresented: $showChapters) { chapterSheet }
        .sheet(isPresented: $showSettings, onDismiss: {
            applyReadingPreferences()
        }) { settingsSheet }
        .alert("阅读错误", isPresented: Binding(get: { model.errorMessage != nil && !model.isLoading }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "未知错误") }
    }

    private var controlsOverlay: some View {
        GeometryReader { proxy in
            let controlsWidth = min(max(proxy.size.width - 40, 0), 360)

            VStack {
                Spacer(minLength: 0)
                controls
                    .frame(width: controlsWidth, alignment: .center)
                    .padding(.bottom, 10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            readerGlassProgressSurface {
                HStack(spacing: 12) {
                    Text("\(Int((model.progression * 100).rounded()))%")
                        .frame(minWidth: 36, alignment: .leading)
                    Slider(value: $sliderProgress, in: 0...1) { editing in
                        isScrubbingProgress = editing
                        if !editing {
                            model.go(to: sliderProgress)
                        }
                    }
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue("百分之 \(Int((sliderProgress * 100).rounded()))")
                    Text(model.totalPositions > 0 ? "\(model.position)/\(model.totalPositions)" : "100%")
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            readerGlassButtonGroup {
                HStack(spacing: 36) {
                    readerGlassButton(action: { model.goBackward() }) {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!model.isNavigatorReady)
                    readerGlassButton(prominent: true, action: { model.toggleSpeech() }) {
                        Image(systemName: model.isSpeaking ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .accessibilityLabel(model.isSpeaking ? "暂停朗读" : "开始朗读")
                    readerGlassButton(action: { model.goForward() }) {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!model.isNavigatorReady)
                }
                .font(.title3)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func readerGlassProgressSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            content()
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content()
                .background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private func readerGlassButtonGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content()
            }
        } else {
            content()
        }
    }

    @ViewBuilder
    private func readerGlassButton<Label: View>(
        prominent: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                Button(action: action, label: label)
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action, label: label)
                    .buttonStyle(.glass)
            }
        } else if prominent {
            Button(action: action, label: label)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
        }
    }

    private var chapterSheet: some View {
        NavigationStack {
            List(Array(model.tableOfContents.enumerated()), id: \.offset) { _, link in
                Button {
                    model.go(to: link); showChapters = false
                } label: { Text(link.title ?? "未命名章节").foregroundStyle(.primary) }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .overlay { if model.tableOfContents.isEmpty { ContentUnavailableView("没有目录", systemImage: "list.bullet") } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapters = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("阅读方式") {
                    Picker("阅读方式", selection: $mode) { ForEach(ReadingMode.allCases) { Text($0.name).tag($0.rawValue) } }.pickerStyle(.segmented)
                }
                Section("显示") {
                    Picker("主题", selection: $theme) { ForEach(ReadingTheme.allCases) { Text($0.name).tag($0.rawValue) } }
                    Picker("字体", selection: $font) { ForEach(ReaderFonts.available) { Text(ReaderFonts.name(for: $0)).tag($0.rawValue) } }
                    LabeledContent("字号", value: "\(Int(fontSize))")
                    Slider(value: $fontSize, in: 15...30, step: 1)
                    LabeledContent("行距", value: "\(Int(lineSpacing))")
                    Slider(value: $lineSpacing, in: 2...16, step: 1)
                }
            }
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct EPUBNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
