import SwiftUI

@main
struct SwiptermApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    private let system = LinuxSystem.shared
    @State private var sessionManager = TerminalSessionManager()
    @State private var setupDraft = SetupDraft()

    var body: some View {
        Group {
            switch system.state {
            case .checking:
                Color.clear
            case .setup, .provisioning:
                NavigationStack {
                    switch system.state {
                    case let .provisioning(provisioning):
                        ProvisioningView(provisioning: provisioning)
                            .id(provisioning.attempt)
                    default:
                        SetupView(draft: $setupDraft)
                    }
                }
            case .booting, .running:
                TerminalContainerView(sessionManager: sessionManager)
            case .halted:
                ContentUnavailableView {
                    Label("System Halted", systemImage: "power")
                } actions: {
                    Button("Restart") {
                        system.restart()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reset", role: .destructive) {
                        system.reset()
                    }
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Start Linux", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .textSelection(.enabled)
                } actions: {
                    Button("Back to Setup") {
                        system.reset()
                    }
                    .buttonStyle(.borderedProminent)
                    if system.installedContainer != nil {
                        Button("Retry") {
                            system.restart()
                        }
                    }
                    Button("Copy Error") {
                        UIPasteboard.general.string = message
                    }
                }
            }
        }
        .modifier(KeepScreenAwakeModifier(isRequired: system.state.keepsScreenAwake))
        .modifier(OpenURLPromptModifier())
        .onChange(of: system.state) { _, state in
            if state == .running {
                setupDraft = SetupDraft()
            }
        }
        .task {
            system.onWillShutdown = {
                sessionManager.closeAll()
            }
            await ImportedFontStore.shared.bootstrap()
            system.bootstrap()
        }
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let isRequired: Bool

    private let settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.keepScreenAwake || isRequired, initial: true) { _, keepsAwake in
                UIApplication.shared.isIdleTimerDisabled = keepsAwake
            }
    }
}
