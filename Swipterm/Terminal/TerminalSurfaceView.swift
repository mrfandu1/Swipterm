import GameController
import GhosttyTerminal
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TerminalSurfaceView: View {
    let surfaceView: SurfaceView
    let state: TerminalViewState
    let isActive: Bool
    let isVisible: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Representable(
            surfaceView: surfaceView,
            isActive: isActive,
            isVisible: isVisible
        )
        .onChange(of: colorScheme, initial: true) {
            state.adopt(colorScheme: colorScheme)
        }
    }

    private struct Representable: UIViewRepresentable {
        let surfaceView: SurfaceView
        let isActive: Bool
        let isVisible: Bool

        func makeUIView(context _: Context) -> HostContainerView {
            let host = HostContainerView()
            host.attach(surfaceView)
            return host
        }

        func updateUIView(_ host: HostContainerView, context _: Context) {
            host.attach(surfaceView)
            surfaceView.setSurfaceVisible(isVisible)
            surfaceView.syncFocus(isActive: isActive && isVisible)
        }

        static func dismantleUIView(_ host: HostContainerView, coordinator _: ()) {
            host.detachIfOwned()
        }
    }

    final class HostContainerView: UIView {
        private weak var attachedSurface: SurfaceView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func attach(_ surface: SurfaceView) {
            guard surface.superview !== self else {
                attachedSurface = surface
                return
            }
            if let old = attachedSurface, old !== surface, old.superview === self {
                old.removeFromSuperview()
            }
            surface.removeFromSuperview()
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            attachedSurface = surface
        }

        func detachIfOwned() {
            guard let surface = attachedSurface else { return }
            if surface.superview === self {
                surface.setSurfaceVisible(false)
                surface.removeFromSuperview()
            }
            attachedSurface = nil
        }
    }

    final class SurfaceView: UITerminalView {
        private static let accessoryPasteActionID = UIAction.Identifier("swipterm.accessory.paste")
        private static let touchPasteActionID = UIAction.Identifier("terminal.paste")

        private var interceptedPresses: Set<UIPress> = []
        private var wantsFocus = false
        private lazy var dropHandler = SurfaceDropDelegate(surfaceView: self)

        override init(frame: CGRect) {
            super.init(frame: frame)
            for interaction in interactions where interaction is UIDropInteraction {
                removeInteraction(interaction)
            }
            addInteraction(UIDropInteraction(delegate: dropHandler))
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidConnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidDisconnect, object: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func syncFocus(isActive: Bool) {
            wantsFocus = isActive
            guard window != nil, isActive != isFirstResponder else { return }
            // A keyboard hide posted while SwiftUI is updating the hosting view leaves that view laid out
            // with the old keyboard height as a fixed bottom edge, which ignoresSafeArea cannot extend past.
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, wantsFocus != isFirstResponder else { return }
                _ = wantsFocus ? becomeFirstResponder() : resignFirstResponder()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, wantsFocus, !isFirstResponder {
                DispatchQueue.main.async { [weak self] in
                    guard let self, wantsFocus, window != nil, !isFirstResponder else { return }
                    _ = becomeFirstResponder()
                }
            }
        }

        override var canBecomeFirstResponder: Bool {
            wantsFocus && super.canBecomeFirstResponder
        }

        override func toggleSoftwareKeyboard() {
            guard wantsFocus else { return }
            super.toggleSoftwareKeyboard()
        }

        override var inputAccessoryItems: [TerminalInputAccessoryItem] {
            didSet {
                if let bar = super.inputAccessoryView {
                    rebindAccessoryPasteButtons(in: bar)
                }
            }
        }

        override var inputAccessoryView: UIView? {
            if GCKeyboard.coalesced != nil {
                return nil
            }
            let bar = super.inputAccessoryView
            if let bar {
                rebindAccessoryPasteButtons(in: bar)
            }
            return bar
        }

        @objc private func hardwareKeyboardDidChange() {
            reloadInputViews()
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                return HostPasteStaging.hasPasteboardContent()
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_: Any?) {
            if markedTextRange != nil {
                unmarkText()
            }
            let pasteboard = UIPasteboard.general
            let fileURLs = HostPasteStaging.fileURLs(in: pasteboard)
            if !fileURLs.isEmpty {
                HostPasteStaging.shared.stageFileURLs(fileURLs) { [weak self] paths in
                    guard let self, let paths else { return }
                    _ = paste(text: paths)
                }
                return
            }

            if pasteboard.hasStrings,
               let text = HostPasteStaging.plainText(
                   string: pasteboard.string,
                   urls: pasteboard.hasURLs ? (pasteboard.urls ?? []) : []
               )
            {
                _ = pasteWithProtection(text: text)
                return
            }

            let providerItems = pasteboard.itemProviders.compactMap { provider in
                HostPasteStaging.stageableType(among: provider.registeredTypeIdentifiers)
                    .map { HostPasteStaging.ProviderItem(provider: provider, type: $0) }
            }
            if !providerItems.isEmpty {
                HostPasteStaging.shared.stageProviders(providerItems) { [weak self] paths in
                    guard let self, let paths else { return }
                    _ = paste(text: paths)
                }
                return
            }

            if pasteboard.hasImages {
                HostPasteStaging.shared.stagePasteboardFallbackImage(pasteboard) { [weak self] paths in
                    guard let self, let paths else { return }
                    _ = paste(text: paths)
                }
                return
            }

            if pasteboard.hasURLs, let text = HostPasteStaging.plainText(string: nil, urls: pasteboard.urls ?? []) {
                _ = pasteWithProtection(text: text)
            }
        }

        override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
            rewireTouchPasteMenu(super.touchMenuItems(for: context))
        }

        override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
            rewireTouchPasteMenu(super.touchSelectionMenuItems(for: context))
        }

        private func rewireTouchPasteMenu(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.map { element in
                if let action = element as? UIAction, action.identifier == Self.touchPasteActionID {
                    return UIAction(
                        title: action.title,
                        image: action.image,
                        identifier: action.identifier,
                        attributes: action.attributes
                    ) { [weak self] _ in
                        self?.paste(nil)
                    }
                }
                if let menu = element as? UIMenu {
                    return menu.replacingChildren(rewireTouchPasteMenu(menu.children))
                }
                return element
            }
        }

        private func rebindAccessoryPasteButtons(in root: UIView) {
            let pasteLabel = TerminalInputAccessoryItem.paste.title
            if let button = root as? UIButton, button.accessibilityLabel == pasteLabel {
                var hasCustomAction = false
                var existingActions: [UIAction] = []
                button.enumerateEventHandlers { action, _, event, _ in
                    guard let action, event.contains(.touchUpInside) else { return }
                    if action.identifier == Self.accessoryPasteActionID {
                        hasCustomAction = true
                    } else {
                        existingActions.append(action)
                    }
                }
                if !hasCustomAction {
                    for action in existingActions {
                        button.removeAction(action, for: .touchUpInside)
                    }
                    button.addAction(UIAction(identifier: Self.accessoryPasteActionID) { [weak self] _ in
                        guard let self else { return }
                        for modifier in [TerminalPublicStickyModifier.ctrl, .alt, .command]
                            where stickyActivation(for: modifier) == .armed
                        {
                            resetStickyModifiers()
                            break
                        }
                        paste(nil)
                    }, for: .touchUpInside)
                }
            }
            for subview in root.subviews {
                rebindAccessoryPasteButtons(in: subview)
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var remaining = presses
            let onCommandKey = (delegate as? TerminalExtras)?.onCommandKey
            for press in presses {
                guard let key = press.key,
                      key.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command
                else { continue }
                let character = key.charactersIgnoringModifiers.lowercased()
                if character == "v" || (key.keyCode == .keyboardV && !character.allSatisfy(\.isASCII)) {
                    paste(nil)
                    interceptedPresses.insert(press)
                    remaining.remove(press)
                    continue
                }
                if onCommandKey?(character) == true {
                    interceptedPresses.insert(press)
                    remaining.remove(press)
                }
            }
            if !remaining.isEmpty {
                super.pressesBegan(remaining, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(interceptedPresses)
            interceptedPresses.subtract(presses)
            if !remaining.isEmpty {
                super.pressesEnded(remaining, with: event)
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(interceptedPresses)
            interceptedPresses.subtract(presses)
            if !remaining.isEmpty {
                super.pressesCancelled(remaining, with: event)
            }
        }
    }

    private final class SurfaceDropDelegate: NSObject, UIDropInteractionDelegate {
        weak var surfaceView: SurfaceView?

        init(surfaceView: SurfaceView) {
            self.surfaceView = surfaceView
        }

        func dropInteraction(_: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            session.items.contains { item in
                HostPasteStaging.stageableType(among: item.itemProvider.registeredTypeIdentifiers) != nil
            }
                || session.canLoadObjects(ofClass: NSURL.self)
                || session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: any UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
            let providerItems = session.items.compactMap { item in
                HostPasteStaging.stageableType(among: item.itemProvider.registeredTypeIdentifiers)
                    .map { HostPasteStaging.ProviderItem(provider: item.itemProvider, type: $0) }
            }
            if !providerItems.isEmpty {
                HostPasteStaging.shared.stageProviders(providerItems) { [weak surfaceView] paths in
                    guard let surfaceView, let paths else { return }
                    _ = surfaceView.paste(text: paths)
                }
                return
            }

            if session.canLoadObjects(ofClass: NSURL.self) {
                let hasText = session.canLoadObjects(ofClass: NSString.self)
                _ = session.loadObjects(ofClass: NSURL.self) { [weak surfaceView] objects in
                    let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
                    let fileURLs = urls.filter(\.isFileURL)
                    if !fileURLs.isEmpty {
                        HostPasteStaging.shared.stageFileURLs(fileURLs) { [weak surfaceView] paths in
                            guard let surfaceView, let paths else { return }
                            _ = surfaceView.paste(text: paths)
                        }
                        return
                    }
                    let deliver: @Sendable (String?) -> Void = { string in
                        Task { @MainActor in
                            guard let surfaceView,
                                  let text = HostPasteStaging.plainText(string: string, urls: urls)
                            else { return }
                            _ = surfaceView.pasteWithProtection(text: text)
                        }
                    }
                    guard hasText else {
                        deliver(nil)
                        return
                    }
                    _ = session.loadObjects(ofClass: NSString.self) { strings in
                        let joined = strings.compactMap { ($0 as? NSString).map { $0 as String } }.joined()
                        deliver(joined)
                    }
                }
                return
            }

            if session.canLoadObjects(ofClass: NSString.self) {
                _ = session.loadObjects(ofClass: NSString.self) { [weak surfaceView] objects in
                    let text = objects.compactMap { ($0 as? NSString).map { $0 as String } }.joined()
                    guard !text.isEmpty else { return }
                    Task { @MainActor in
                        _ = surfaceView?.pasteWithProtection(text: text)
                    }
                }
            }
        }
    }
}
