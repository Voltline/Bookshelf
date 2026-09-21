import AVFoundation
import Combine
import Foundation
@preconcurrency import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

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
    private var verticalScrollNavigationAdapter: VerticalScrollNavigationAdapter?
    private var speechSettings = SpeechSettings()
    private var positionCountsByReadingOrder: [Int] = []
    private var highlightedUtterance: Locator?
    private var lastSpeechNavigationAt = Date.distantPast
    private var isSpeechNavigating = false

    init(book: Book, store: LibraryStore) {
        self.book = book
        self.store = store
    }

    func load(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme, font: ReadingFont, speechSettings: SpeechSettings) async {
        guard navigator == nil else { return }
        isLoading = true
        self.speechSettings = speechSettings
        do {
            let publication = try await store.publication(for: book)
            let savedLocation = try book.locator.locatorJSON.flatMap { try Locator(jsonString: $0) }
            let initialLocation = validatedInitialLocation(savedLocation, in: publication)
            let preferences = makePreferences(fontSize: fontSize, lineSpacing: lineSpacing, mode: mode, theme: theme, font: font)
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(
                    preferences: preferences,
                    disablePageTurnsWhileScrolling: true
                )
            )
            navigator.delegate = self

            let adapter = DirectionalNavigationAdapter(animatedTransition: true)
            adapter.bind(to: navigator)
            let verticalScrollAdapter = VerticalScrollNavigationAdapter(navigator: navigator)
            verticalScrollAdapter.bind()
            navigator.addObserver(.activate { [weak self] _ in
                self?.controlsVisible.toggle()
                return true
            })

            self.publication = publication
            self.navigator = navigator
            navigationAdapter = adapter
            verticalScrollNavigationAdapter = verticalScrollAdapter
            tableOfContents = flatten((try? await publication.tableOfContents().get()) ?? [])
            positionCountsByReadingOrder = ((try? await publication.positionsByReadingOrder().get()) ?? []).map(\.count)
            totalPositions = positionCountsByReadingOrder.reduce(0, +)
            if let location = navigator.currentLocation ?? initialLocation {
                updateReadingProgress(from: location)
            }
            speechSynthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: .init(
                    defaultLanguage: Language(code: .bcp47(speechSettings.languageCode)),
                    voiceIdentifier: speechSettings.engine == .kokoro ? "kokoro.\(speechSettings.kokoroVoice)" : (speechSettings.voiceIdentifier.isEmpty ? nil : speechSettings.voiceIdentifier)
                ),
                engineFactory: { [weak self] in
                    if speechSettings.engine == .kokoro { return KokoroTTSEngine(settings: speechSettings) }
                    return AVTTSEngine(delegate: self)
                },
                delegate: self
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func applyPreferences(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme, font: ReadingFont) {
        navigator?.submitPreferences(makePreferences(fontSize: fontSize, lineSpacing: lineSpacing, mode: mode, theme: theme, font: font))
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
        if speechSettings.engine == .kokoro && !KokoroModel.isInstalled {
            errorMessage = "请先到书架 → 设置下载 Kokoro 模型，或将朗读引擎切回系统朗读。"
            return
        }
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
        if speechSettings.engine == .kokoro { Task { await KokoroWorker.shared.unload() } }
        updateSpeechHighlight(nil)
    }

    private func makePreferences(fontSize: Double, lineSpacing: Double, mode: ReadingMode, theme: ReadingTheme, font: ReadingFont) -> EPUBPreferences {
        EPUBPreferences(
            fontFamily: ReaderFonts.family(for: font),
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

    private func updateReadingProgress(from locator: Locator, persist: Bool = true) {
        let fallbackProgress = min(1, max(0, locator.locations.totalProgression ?? progression))
        var resolvedProgress = fallbackProgress
        var resolvedPosition = locator.locations.position

        if
            totalPositions > 0,
            let publication,
            let resourceIndex = publication.readingOrder.firstIndex(where: { $0.url().isEquivalentTo(locator.href) }),
            positionCountsByReadingOrder.indices.contains(resourceIndex)
        {
            let positionsBeforeResource = positionCountsByReadingOrder[..<resourceIndex].reduce(0, +)
            let positionsInResource = positionCountsByReadingOrder[resourceIndex]

            if positionsInResource > 0 {
                let inferredResourceProgress = resolvedPosition.map {
                    Double(max(0, $0 - positionsBeforeResource - 1)) / Double(positionsInResource)
                }
                let resourceProgress = min(1, max(0, locator.locations.progression ?? inferredResourceProgress ?? 0))
                resolvedProgress = min(
                    1,
                    max(0, (Double(positionsBeforeResource) + resourceProgress * Double(positionsInResource)) / Double(totalPositions))
                )
                let localPosition = min(positionsInResource - 1, Int(floor(resourceProgress * Double(positionsInResource))))
                resolvedPosition = positionsBeforeResource + localPosition + 1
            }
        }

        if totalPositions > 0 {
            resolvedPosition = min(totalPositions, max(1, resolvedPosition ?? Int((resolvedProgress * Double(totalPositions - 1)).rounded()) + 1))
        } else {
            resolvedPosition = max(1, resolvedPosition ?? 1)
        }

        progression = resolvedProgress
        position = resolvedPosition ?? 1

        if persist {
            store.updateLocation(
                bookID: book.id,
                locatorJSON: locator.jsonString,
                position: position,
                total: totalPositions
            )
        }
    }
}

/// Readium scrolls continuously inside one spine item, but its built-in
/// cross-chapter gesture is horizontal. This adapter keeps scroll mode
/// vertical by turning to the adjacent spine item when the user swipes again
/// at the top or bottom edge of the current item.
@MainActor
private final class VerticalScrollNavigationAdapter: NSObject, UIGestureRecognizerDelegate {
    private enum Direction {
        case backward, forward
    }

    private weak var navigator: EPUBNavigatorViewController?
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private var pendingDirection: Direction?
    private var isNavigating = false

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
    }

    func bind() {
        guard let view = navigator?.view else { return }
        panGesture.delegate = self
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        pendingDirection = nil
        guard
            !isNavigating,
            let navigator,
            navigator.presentation.scroll,
            let scrollView = activeWebScrollView(in: navigator),
            let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }

        let velocity = pan.velocity(in: navigator.view)
        guard abs(velocity.y) > abs(velocity.x) * 1.15 else { return false }

        let inset = scrollView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let tolerance = 2.0

        if velocity.y < 0, scrollView.contentOffset.y >= maximumY - tolerance {
            pendingDirection = .forward
            return true
        }
        if velocity.y > 0, scrollView.contentOffset.y <= minimumY + tolerance {
            pendingDirection = .backward
            return true
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let direction = pendingDirection, let navigator else {
            if gesture.state == .cancelled || gesture.state == .failed {
                pendingDirection = nil
            }
            return
        }
        pendingDirection = nil

        let translationY = gesture.translation(in: navigator.view).y
        let velocityY = gesture.velocity(in: navigator.view).y
        let shouldNavigate: Bool = {
            switch direction {
            case .forward: translationY < -44 || velocityY < -550
            case .backward: translationY > 44 || velocityY > 550
            }
        }()
        guard shouldNavigate else { return }

        isNavigating = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isNavigating = false }
            guard let navigator = self.navigator else { return }
            switch direction {
            case .forward:
                _ = await navigator.goForward(options: .animated)
            case .backward:
                _ = await navigator.goBackward(options: .animated)
            }
        }
    }

    private func activeWebScrollView(in navigator: EPUBNavigatorViewController) -> UIScrollView? {
        let viewport = navigator.view.bounds
        return navigator.view
            .descendants(of: WKWebView.self)
            .map { webView in
                (scrollView: webView.scrollView, visibleArea: webView.convert(webView.bounds, to: navigator.view).intersection(viewport).area)
            }
            .filter { $0.visibleArea > 1 }
            .max { $0.visibleArea < $1.visibleArea }?
            .scrollView
    }
}

private extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view in
            (view as? T).map { [$0] } ?? view.descendants(of: type)
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}

extension ReadiumReaderModel: EPUBNavigatorDelegate {
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        // Readium intentionally preserves author fonts on elements carrying a
        // language attribute. Many CJK EPUBs wrap every sentence in such
        // spans, which makes the standard font preference appear ineffective.
        // Keep Readium's CSS variable as the source of truth, but extend the
        // override to normal text elements regardless of their lang attribute.
        let source = #"""
        (() => {
          if (document.getElementById("bookshelf-font-override")) return;
          const style = document.createElement("style");
          style.id = "bookshelf-font-override";
          style.textContent = `
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] {
              font-family: var(--USER__fontFamily) !important;
            }
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] body,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] p,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] li,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] div,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] blockquote,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h1,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h2,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h3,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h4,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h5,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] h6,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] span,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] a,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] em,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] strong,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] ruby,
            :root[style*="readium-font-on"][style*="--USER__fontFamily"] rt {
              font-family: var(--USER__fontFamily) !important;
            }
          `;
          (document.head || document.documentElement).appendChild(style);
        })();
        """#
        userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
    }

    func navigator(_ navigator: EPUBNavigatorViewController, viewportDidChange viewport: EPUBNavigatorViewController.Viewport?) {
        isNavigatorReady = viewport != nil
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        updateReadingProgress(from: locator)
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
