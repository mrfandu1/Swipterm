import SwiftUI

@main
struct SwiptermApp: App {
    var body: some Scene {
        WindowGroup {
            #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                StoreScreenshotBatch { ContentView() }
            #else
                ContentView()
            #endif
        }
    }
}

private struct ContentView: View {
    private let system = LinuxSystem.shared
    @State private var sessionManager = TerminalSessionManager()
    @State private var setupDraft = SetupDraft()

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        @Environment(\.locale) private var screenshotLocale
    #endif

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
                #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                .id(screenshotLocale)
                #endif
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
        #if !SWIPTERM_STORE_SCREENSHOTS || !targetEnvironment(simulator)
        .task {
            system.onWillShutdown = {
                sessionManager.closeAll()
            }
            #if DEBUG || SIDELOAD
                SwiptJIT.shared.start()
            #endif
            await ImportedFontStore.shared.bootstrap()
            system.bootstrap()
        }
        #endif
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let isRequired: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isRequired, initial: true) { _, keepsAwake in
                UIApplication.shared.isIdleTimerDisabled = keepsAwake
            }
    }
}
