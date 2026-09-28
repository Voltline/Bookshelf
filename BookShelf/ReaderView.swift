import ReadiumNavigator
import ReadiumShared
import SwiftUI

struct ReaderView: View {
    private enum Panel: String, CaseIterable {
        case chapters = "目录"
        case highlights = "划线"
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReadiumReaderModel
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var theme = ReadingTheme.paper.rawValue
    @AppStorage("reader.mode") private var mode = ReadingMode.page.rawValue
    @AppStorage("reader.font") private var font = ReadingFont.publisher.rawValue
    @AppStorage(SpeechSettingKeys.language) private var speechLanguage = "zh-CN"
    @AppStorage(SpeechSettingKeys.voiceIdentifier) private var speechVoiceIdentifier = ""
    @AppStorage(SpeechSettingKeys.rate) private var speechRate = 0.5
    @AppStorage(SpeechSettingKeys.pitch) private var speechPitch = 1.0
    @AppStorage(SpeechSettingKeys.volume) private var speechVolume = 1.0
    @AppStorage(SpeechSettingKeys.sentencePause) private var speechSentencePause = 0.0
    @AppStorage(SpeechSettingKeys.highlightEnabled) private var speechHighlightEnabled = true
    @AppStorage(SpeechSettingKeys.autoPageTurnEnabled) private var speechAutoPageTurnEnabled = true
    @State private var showChapters = false
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var sliderProgress = 0.0
    @State private var isScrubbingProgress = false
    @State private var panel: Panel = .chapters
    @State private var editingMark: ReaderMark?

    init(book: Book, library: LibraryStore, initialSearchLocator: Locator? = nil) {
        _model = StateObject(wrappedValue: ReadiumReaderModel(book: book, store: library, initialSearchLocator: initialSearchLocator))
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
            autoPageTurnEnabled: speechAutoPageTurnEnabled
        )
    }

    var body: some View {
        ZStack {
            if let navigator = model.navigator {
                EPUBNavigatorContainer(
                    navigator: navigator,
                    onHighlight: { locator in
                        if let mark = model.makeHighlight(at: locator) { model.saveReaderMark(mark) }
                    },
                    onNote: { locator in
                        editingMark = model.makeHighlight(at: locator)
                    },
                    onMarkTap: { id in
                        editingMark = model.readerMarks.first(where: { $0.id == id })
                    }
                )
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
        .toolbar(.hidden, for: .tabBar)
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
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索本书正文")
                .disabled(model.publication == nil)
                Button { showChapters = true } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("目录与划线")
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
        .sheet(item: $editingMark) { mark in
            NavigationStack { markEditor(for: mark) }
        }
        .sheet(isPresented: $showSearch) { BookFullTextSearchView(model: model).presentationDetents([.large]) }
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
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            readerGlassButtonGroup {
                HStack(spacing: 28) {
                    readerGlassButton(action: { model.goBackward() }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .disabled(!model.isNavigatorReady)
                    readerGlassButton(prominent: true, action: { model.toggleSpeech() }) {
                        Image(systemName: model.isSpeaking ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .offset(x: model.isSpeaking ? 0 : 1)
                    }
                    .accessibilityLabel(model.isSpeaking ? "暂停朗读" : "开始朗读")
                    readerGlassButton(action: { model.goForward() }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .disabled(!model.isNavigatorReady)
                }
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
        let buttonSize: CGFloat = prominent ? 62 : 52
        let labelSize: CGFloat = prominent ? 38 : 32

        if #available(iOS 26.0, *) {
            if prominent {
                Button(action: action) {
                    label()
                        .frame(width: labelSize, height: labelSize)
                }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .frame(width: buttonSize, height: buttonSize)
            } else {
                Button(action: action) {
                    label()
                        .frame(width: labelSize, height: labelSize)
                }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(width: buttonSize, height: buttonSize)
            }
        } else if prominent {
            Button(action: action) {
                label()
                    .frame(width: labelSize, height: labelSize)
            }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .frame(width: buttonSize, height: buttonSize)
        } else {
            Button(action: action) {
                label()
                    .frame(width: labelSize, height: labelSize)
            }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .frame(width: buttonSize, height: buttonSize)
        }
    }

    private var chapterSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("内容", selection: $panel) {
                    ForEach(Panel.allCases, id: \.self) { panel in Text(panel.rawValue).tag(panel) }
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    switch panel {
                    case .chapters:
                        ForEach(Array(model.tableOfContents.enumerated()), id: \.offset) { _, link in
                            Button {
                                model.go(to: link)
                                showChapters = false
                            } label: { Text(link.title ?? "未命名章节").foregroundStyle(.primary) }
                        }
                    case .highlights:
                        ForEach(model.readerMarks.filter { $0.kind == .highlight }.sorted { $0.createdAt > $1.createdAt }) { mark in
                            NavigationLink {
                                markEditor(for: mark)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mark.excerpt).lineLimit(3)
                                    Text(mark.note.isEmpty ? mark.chapter : mark.note)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { model.removeReaderMark(mark) }
                            }
                        }
                    }
                }
                .overlay {
                    if panel == .chapters && model.tableOfContents.isEmpty {
                        ContentUnavailableView("没有目录", systemImage: "list.bullet")
                    } else if panel == .highlights && !model.readerMarks.contains(where: { $0.kind == .highlight }) {
                        ContentUnavailableView("还没有划线", systemImage: "highlighter", description: Text("长按正文选中文字即可添加。"))
                    }
                }
            }
            .navigationTitle("目录与标注").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapters = false } } }
        }.presentationDetents([.medium, .large])
    }

    private func markEditor(for mark: ReaderMark) -> some View {
        ReaderMarkEditor(
            mark: mark,
            isSaved: model.readerMarks.contains(where: { $0.id == mark.id }),
            onSave: { model.saveReaderMark($0) },
            onDelete: { model.removeReaderMark(mark) },
            onGoTo: {
                model.go(to: mark)
                showChapters = false
                editingMark = nil
            }
        )
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
