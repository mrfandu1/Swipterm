import GameController
import GhosttyTerminal
import SwiftUI
import UIKit

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
        private var interceptedPresses: Set<UIPress> = []
        private var wantsFocus = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidConnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidDisconnect, object: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func syncFocus(isActive: Bool) {
            wantsFocus = isActive
            if isActive {
                guard window != nil else { return }
                if !isFirstResponder {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, wantsFocus, window != nil, !isFirstResponder else { return }
                        _ = becomeFirstResponder()
                    }
                }
            } else if isFirstResponder {
                _ = resignFirstResponder()
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

        override var inputAccessoryView: UIView? {
            if GCKeyboard.coalesced != nil, (delegate as? TerminalExtras)?.alwaysShowsSymbolBar != true {
                return nil
            }
            return super.inputAccessoryView
        }

        @objc private func hardwareKeyboardDidChange() {
            reloadInputViews()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var remaining = presses
            if let onCommandKey = (delegate as? TerminalExtras)?.onCommandKey {
                for press in presses {
                    guard let key = press.key,
                          key.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command,
                          onCommandKey(key.charactersIgnoringModifiers.lowercased())
                    else { continue }
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
}
