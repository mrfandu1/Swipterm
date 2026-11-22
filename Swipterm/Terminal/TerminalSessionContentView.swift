import GhosttyTerminal
import SwiftUI

struct TerminalSessionContentView: View {
    let session: TerminalSession
    let isActive: Bool
    let isVisible: Bool
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            TerminalSurfaceView(
                surfaceView: session.surfaceView,
                state: session.state,
                isActive: isActive,
                isVisible: isVisible
            )
            TerminalSessionOverlayView(
                phase: session.phase,
                hasVisibleOutput: session.hasVisibleOutput,
                onClose: onClose
            )
            .environment(\.colorScheme, overlayColorScheme)
        }
        .accessibilityHidden(!isVisible)
    }

    private var backgroundColor: Color {
        if let terminalColor = session.backgroundColor {
            return Color(terminalColor)
        }
        return Color(uiColor: .systemBackground)
    }

    private var overlayColorScheme: ColorScheme {
        guard let terminalColor = session.backgroundColor else {
            return colorScheme
        }
        let luminance = 0.2126 * Double(terminalColor.red)
            + 0.7152 * Double(terminalColor.green)
            + 0.0722 * Double(terminalColor.blue)
        return luminance < 128 ? .dark : .light
    }
}

private struct TerminalSessionOverlayView: View {
    let phase: TerminalSession.Phase
    let hasVisibleOutput: Bool
    let onClose: () -> Void

    var body: some View {
        switch phase {
        case .starting, .running:
            if !hasVisibleOutput {
                ProgressView()
                    .controlSize(.large)
            }
        case let .finished(reason):
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Text(reason.displayText)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Close", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding()
            }
        }
    }
}
