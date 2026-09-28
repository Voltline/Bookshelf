import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

struct EPUBNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onHighlight: (Locator) -> Void
    let onNote: (Locator) -> Void
    let onMarkTap: (UUID) -> Void

    func makeUIViewController(context: Context) -> ReaderNavigatorHostController {
        ReaderNavigatorHostController(
            navigator: navigator,
            onHighlight: onHighlight,
            onNote: onNote,
            onMarkTap: onMarkTap
        )
    }

    func updateUIViewController(_ controller: ReaderNavigatorHostController, context: Context) {
        controller.onHighlight = onHighlight
        controller.onNote = onNote
        controller.onMarkTap = onMarkTap
    }
}

@MainActor
final class ReaderNavigatorHostController: UIViewController {
    let navigator: EPUBNavigatorViewController
    var onHighlight: (Locator) -> Void
    var onNote: (Locator) -> Void
    var onMarkTap: (UUID) -> Void

    init(
        navigator: EPUBNavigatorViewController,
        onHighlight: @escaping (Locator) -> Void,
        onNote: @escaping (Locator) -> Void,
        onMarkTap: @escaping (UUID) -> Void
    ) {
        self.navigator = navigator
        self.onHighlight = onHighlight
        self.onNote = onNote
        self.onMarkTap = onMarkTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        navigator.observeDecorationInteractions(inGroup: "reader-marks") { [weak self] event in
            guard let id = UUID(uuidString: event.decoration.id) else { return }
            self?.onMarkTap(id)
        }
    }

    @objc func highlightSelection() {
        guard let locator = navigator.currentSelection?.locator else { return }
        onHighlight(locator)
        navigator.clearSelection()
    }

    @objc func noteSelection() {
        guard let locator = navigator.currentSelection?.locator else { return }
        onNote(locator)
        navigator.clearSelection()
    }
}
