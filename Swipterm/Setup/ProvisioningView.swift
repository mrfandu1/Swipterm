import Combine
import GhosttyTerminal
import SwiftUI

struct ProvisioningView: View {
    let provisioning: LinuxSystem.Provisioning

    private let system = LinuxSystem.shared

    @State private var terminal = SetupTerminal()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            TerminalSurfaceView(
                surfaceView: terminal.surfaceView,
                state: terminal.state,
                isActive: false,
                isVisible: true
            )
            if !terminal.hasVisibleOutput, provisioning.failure == nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = provisioning.failure {
                failureCard(failure)
                    .environment(\.colorScheme, overlayColorScheme)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if provisioning.failure == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        system.reset()
                    }
                }
            }
        }
        .onAppear {
            terminal.attach()
        }
        .onDisappear {
            terminal.detach()
        }
    }

    private func failureCard(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(failure)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.callout)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    backButton
                    Spacer(minLength: 0)
                    copyButton
                    retryButton
                }
                VStack(spacing: 8) {
                    retryButton
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        copyButton
                            .frame(maxWidth: .infinity)
                        backButton
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
    }

    private var retryButton: some View {
        Button("Retry") {
            system.retrySetup()
        }
        .buttonStyle(.borderedProminent)
    }

    private var copyButton: some View {
        Button("Copy Output") {
            UIPasteboard.general.string = system.consoleText
        }
        .buttonStyle(.bordered)
    }

    private var backButton: some View {
        Button("Back to Setup", role: .destructive) {
            system.reset()
        }
        .buttonStyle(.bordered)
    }

    private var backgroundColor: Color {
        if let terminalColor = terminal.backgroundColor {
            return Color(terminalColor)
        }
        return Color(uiColor: .systemBackground)
    }

    private var overlayColorScheme: ColorScheme {
        guard let terminalColor = terminal.backgroundColor else {
            return colorScheme
        }
        let luminance = 0.2126 * Double(terminalColor.red)
            + 0.7152 * Double(terminalColor.green)
            + 0.0722 * Double(terminalColor.blue)
        return luminance < 128 ? .dark : .light
    }
}

@Observable
private final class SetupTerminal {
    let state: TerminalViewState
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var hasVisibleOutput = LinuxSystem.shared.hasConsoleOutput
    private(set) var backgroundColor: TerminalColor?

    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let extras = TerminalExtras()
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init() {
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { viewport in
                let columns = UInt16(clamping: viewport.columns)
                let rows = UInt16(clamping: viewport.rows)
                Task { @MainActor in
                    LinuxSystem.shared.resizeSetupTerminal(columns: columns, rows: rows)
                }
            }
        )
        state = TerminalViewState(
            configSource: .none,
            theme: TerminalAppearance.theme(),
            terminalConfiguration: TerminalAppearance.fontConfiguration()
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        extras.state = state

        let view = TerminalSurfaceView.SurfaceView(frame: .zero)
        view.controller = state.controller
        view.configuration = state.configuration
        view.delegate = extras
        surfaceView = view

        state.$backgroundColor
            .sink { [weak self] color in
                self?.backgroundColor = color
            }
            .store(in: &cancellables)
    }

    func attach() {
        guard subscription == nil else { return }
        let session = session
        subscription = LinuxSystem.shared.subscribeConsole { [weak self] data in
            session.receive(data)
            if self?.hasVisibleOutput == false {
                self?.hasVisibleOutput = true
            }
        }
    }

    func detach() {
        if let subscription {
            LinuxSystem.shared.unsubscribeConsole(subscription)
        }
        subscription = nil
        surfaceView.setSurfaceVisible(false)
    }
}
