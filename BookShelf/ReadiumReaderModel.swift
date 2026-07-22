import AVFoundation
import Combine
import Foundation
@preconcurrency import ReadiumNavigator
import ReadiumShared
import UIKit

@MainActor
final class ReadiumReaderModel: NSObject, ObservableObject {
    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var publication: Publication?
    @Published private(set) var tableOfContents: [Link] = []
    @Published private(set) var position = 1
    @Published private(set) var totalPositions = 0
    @Published var progression = 0.0
    @Published var isLoading = true
    @Published private(set) var isNavigatorReady = false
    @Published var isSpeaking = false
    @Published var controlsVisible = true
    @Published var errorMessage: String?

    let book: Book
    private let store: LibraryStore
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var speechSettings = SpeechSettings()
    private var highlightedUtterance: Locator?
    private var lastSpeechNavigationAt = Date.distantPast
    private var isSpeechNavigating = false

    init(book: Book, store: LibraryStore) {
        self.book = book
        self.store = store
    }

    func load(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme, speechSettings: SpeechSettings) async {
        guard navigator == nil else { return }
        isLoading = true
        self.speechSettings = speechSettings
        do {
            let publication = try await store.publication(for: book)
            let savedLocation = try book.locator.locatorJSON.flatMap { try Locator(jsonString: $0) }
            let initialLocation = validatedInitialLocation(savedLocation, in: publication)
            let preferences = makePreferences(fontSize: fontSize, lineSpacing: lineSpacing, mode: mode, theme: theme)
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(preferences: preferences)
            )
            navigator.delegate = self

            let adapter = DirectionalNavigationAdapter(animatedTransition: true)
            adapter.bind(to: navigator)
            navigator.addObserver(.activate { [weak self] _ in
                self?.controlsVisible.toggle()
                return true
            })

            self.publication = publication
            self.navigator = navigator
            navigationAdapter = adapter
            tableOfContents = flatten((try? await publication.tableOfContents().get()) ?? [])
            speechSynthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: .init(
                    defaultLanguage: Language(code: .bcp47(speechSettings.languageCode)),
                    voiceIdentifier: speechSettings.voiceIdentifier.isEmpty ? nil : speechSettings.voiceIdentifier
                ),
                engineFactory: { [weak self] in AVTTSEngine(delegate: self) },
                delegate: self
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func applyPreferences(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme) {
        navigator?.submitPreferences(makePreferences(fontSize: fontSize, lineSpacing: lineSpacing, mode: mode, theme: theme))
    }

    func goForward() {
        Task {
            guard let navigator, isNavigatorReady else { return }
            if await navigator.goForward(options: .animated) == false {
                await moveToAdjacentResource(offset: 1, navigator: navigator)
            }
        }
    }

    func goBackward() {
        Task {
            guard let navigator, isNavigatorReady else { return }
            if await navigator.goBackward(options: .animated) == false {
                await moveToAdjacentResource(offset: -1, navigator: navigator)
            }
        }
    }
    func go(to link: Link) { Task { await navigator?.go(to: link, options: .animated) } }

    func go(to progression: Double) {
        guard let publication, let navigator else { return }
        Task {
            if let locator = await publication.locate(progression: min(1, max(0, progression))) {
                _ = await navigator.go(to: locator, options: .animated)
            }
        }
    }

    func toggleSpeech() {
        guard let synthesizer = speechSynthesizer else { return }
        switch synthesizer.state {
        case .stopped:
            Task {
                let start = await navigator?.firstVisibleElementLocator() ?? navigator?.currentLocation
                synthesizer.start(from: start)
            }
        case .paused, .playing:
            synthesizer.pauseOrResume()
        }
    }

    func stopSpeech() {
        speechSynthesizer?.stop()
        updateSpeechHighlight(nil)
    }

    private func makePreferences(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme) -> EPUBPreferences {
        EPUBPreferences(
            fontFamily: .serif,
            fontSize: max(0.7, min(2.0, fontSize / 20.0)),
            lineHeight: max(1.1, min(2.2, 1.25 + lineSpacing / 20.0)),
            publisherStyles: true,
            scroll: mode == .scroll,
            theme: {
                switch theme {
                case .paper: ReadiumNavigator.Theme.light
                case .sepia: ReadiumNavigator.Theme.sepia
                case .night: ReadiumNavigator.Theme.dark
                }
            }()
        )
    }

    private func flatten(_ links: [Link]) -> [Link] {
        links.flatMap { [$0] + flatten($0.children) }
    }

    private func validatedInitialLocation(_ locator: Locator?, in publication: Publication) -> Locator? {
        guard
            let locator,
            (locator.locations.totalProgression ?? 1) <= 0.01,
            (locator.locations.position ?? 2) <= 1,
            let index = publication.readingOrder.firstIndex(where: { $0.url().isEquivalentTo(locator.href) }),
            index >= max(1, publication.readingOrder.count / 2)
        else { return locator }

        // Older builds could receive a one-item spine from malformed EPUBs
        // and save the last chapter as position 1 / 0%. That locator is
        // internally contradictory once the spine has been repaired.
        return nil
    }

    private func moveToAdjacentResource(offset: Int, navigator: EPUBNavigatorViewController) async {
        guard
            let publication,
            let href = navigator.currentLocation?.href,
            let currentIndex = publication.readingOrder.firstIndex(where: { $0.url().isEquivalentTo(href) })
        else { return }

        let targetIndex = currentIndex + offset
        guard publication.readingOrder.indices.contains(targetIndex) else { return }
        _ = await navigator.go(to: publication.readingOrder[targetIndex], options: .animated)
    }

    private func updateSpeechHighlight(_ locator: Locator?) {
        guard highlightedUtterance != locator else { return }
        highlightedUtterance = locator
        guard let navigator else { return }

        let decorations: [Decoration]
        if speechSettings.highlightEnabled, let locator {
            decorations = [Decoration(
                id: "tts-current-utterance",
                locator: locator,
                style: .highlight(tint: UIColor.systemYellow.withAlphaComponent(0.45))
            )]
        } else {
            decorations = []
        }
        navigator.apply(decorations: decorations, in: "tts")
    }

    private func followSpokenWord(_ locator: Locator) {
        guard speechSettings.autoPageTurnEnabled, !isSpeechNavigating else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpeechNavigationAt) >= 0.8 else { return }
        lastSpeechNavigationAt = now
        isSpeechNavigating = true

        Task { [weak self] in
            guard let self, let navigator = self.navigator else { return }
            _ = await navigator.go(to: locator, options: .none)
            self.isSpeechNavigating = false
        }
    }
}

extension ReadiumReaderModel: EPUBNavigatorDelegate {
    func navigator(_ navigator: EPUBNavigatorViewController, viewportDidChange viewport: EPUBNavigatorViewController.Viewport?) {
        isNavigatorReady = viewport != nil
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        progression = locator.locations.totalProgression ?? progression
        position = locator.locations.position ?? max(1, Int(progression * Double(max(1, totalPositions))))
        store.updateLocation(bookID: book.id, locatorJSON: locator.jsonString, position: position, total: totalPositions)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = "阅读器发生错误：\(error)"
    }
}

extension ReadiumReaderModel: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange state: PublicationSpeechSynthesizer.State) {
        switch state {
        case .stopped:
            isSpeaking = false
            updateSpeechHighlight(nil)
        case let .paused(utterance):
            isSpeaking = false
            updateSpeechHighlight(utterance.locator)
        case let .playing(utterance, range):
            isSpeaking = true
            updateSpeechHighlight(utterance.locator)
            if let range { followSpokenWord(range) }
        }
    }

    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error) {
        isSpeaking = false
        errorMessage = "语音朗读失败：\(error)"
    }
}

extension ReadiumReaderModel: AVTTSEngineDelegate {
    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        utterance.rate = Float(speechSettings.rate)
        utterance.pitchMultiplier = Float(speechSettings.pitch)
        utterance.volume = Float(speechSettings.volume)
        utterance.preUtteranceDelay += speechSettings.sentencePause
    }
}
