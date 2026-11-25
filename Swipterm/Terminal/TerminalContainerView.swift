import GhosttyTerminal
import Observation
import SwiftUI
import UIKit

struct TerminalContainerView: View {
    private let system = LinuxSystem.shared
    let sessionManager: TerminalSessionManager

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var splitState = TerminalSplitPresentationState()
    @State private var showSettings = false
    @State private var pendingPaste: TerminalClipboardConfirmationRequest?

    var body: some View {
        TerminalSplitViewRepresentable(
            sessionManager: sessionManager,
            splitState: splitState,
            actualHorizontalSizeClass: horizontalSizeClass,
            onOpenSettings: { showSettings = true },
            onSetupCallbacks: setupCallbacks
        )
        .ignoresSafeArea()
        .background {
            TerminalKeyboardShortcuts(
                onNewSession: { sessionManager.addSession() },
                onCloseSession: closeActiveSession,
                onPreviousSession: { sessionManager.selectAdjacentSession(offset: -1) },
                onNextSession: { sessionManager.selectAdjacentSession(offset: 1) },
                onOpenSettings: { showSettings = true }
            )
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .alert(
            "Paste Potentially Unsafe Text?",
            isPresented: Binding {
                pendingPaste != nil
            } set: { isPresented in
                if !isPresented {
                    pendingPaste = nil
                }
            },
            presenting: pendingPaste
        ) { request in
            Button("Paste") {
                request.respond(allow: true)
            }
            Button("Cancel", role: .cancel) {
                request.respond(allow: false)
            }
        } message: { _ in
            Text("This text contains line breaks and may run commands as soon as it is pasted.")
        }
        .onChange(of: showSettings, initial: true) { _, isPresented in
            splitState.isSettingsPresented = isPresented
        }
        .onChange(of: sessionManager.sessions.isEmpty) { _, isEmpty in
            if isEmpty, system.state == .booting || system.state == .running {
                sessionManager.ensureInitialSession()
            }
        }
        .onAppear {
            sessionManager.ensureInitialSession()
        }
    }

    private func closeActiveSession() {
        if let id = sessionManager.activeSessionID {
            sessionManager.closeSession(id: id)
        }
    }

    private func setupCallbacks(for session: TerminalSession) {
        session.extras.onOpenURL = { urlString, _ in
            guard let url = URL(string: urlString) else { return }
            system.pendingOpenURL = url
        }
        session.extras.onPasteConfirmation = { request in
            pendingPaste = request
        }
        session.extras.onCommandKey = { key in
            switch key {
            case "n", "t":
                sessionManager.addSession()
                return true
            case "w":
                sessionManager.closeSession(id: session.id)
                return true
            case ",":
                showSettings = true
                return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let index = Int(key) {
                    sessionManager.selectSession(at: index - 1)
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

@Observable
private final class TerminalSplitPresentationState {
    var isSidebarOverlayVisible = false
    var isSettingsPresented = false

    var isTerminalInputActive: Bool {
        !isSidebarOverlayVisible && !isSettingsPresented
    }
}

/// Host UISplitViewController directly so compact screens use UIKit's native floating
/// overlay sidebar instead of collapsing to a push stack or hand-rolling a drawer.
private struct TerminalSplitViewRepresentable: UIViewControllerRepresentable {
    let sessionManager: TerminalSessionManager
    let splitState: TerminalSplitPresentationState
    let actualHorizontalSizeClass: UserInterfaceSizeClass?
    let onOpenSettings: () -> Void
    let onSetupCallbacks: (TerminalSession) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(splitState: splitState, onOpenSettings: onOpenSettings)
    }

    func makeUIViewController(context: Context) -> UISplitViewController {
        let splitViewController = UISplitViewController(style: .doubleColumn)
        splitViewController.delegate = context.coordinator
        splitViewController.primaryBackgroundStyle = .sidebar
        splitViewController.presentsWithGesture = true
        splitViewController.displayModeButtonVisibility = .always
        splitViewController.preferredDisplayMode = .secondaryOnly
        splitViewController.minimumPrimaryColumnWidth = 260
        splitViewController.preferredPrimaryColumnWidth = 300
        splitViewController.maximumPrimaryColumnWidth = 320

        let coordinator = context.coordinator
        let primaryHosting = UIHostingController(
            rootView: TerminalSidebarView(
                sessionManager: sessionManager,
                onSelectSession: { coordinator.hideSidebarIfOverlay() },
                onOpenSettings: {
                    coordinator.hideSidebarIfOverlay()
                    coordinator.onOpenSettings()
                }
            )
        )
        primaryHosting.view.backgroundColor = .clear
        let secondaryHosting = UIHostingController(
            rootView: TerminalDetailView(
                sessionManager: sessionManager,
                splitState: splitState,
                onSetupCallbacks: onSetupCallbacks
            )
        )

        coordinator.splitViewController = splitViewController
        coordinator.primaryHosting = primaryHosting
        coordinator.secondaryHosting = secondaryHosting

        splitViewController.setViewController(primaryHosting, for: .primary)
        splitViewController.setViewController(secondaryHosting, for: .secondary)

        applyLayoutBehavior(to: splitViewController, coordinator: coordinator)
        return splitViewController
    }

    func updateUIViewController(_ splitViewController: UISplitViewController, context: Context) {
        context.coordinator.onOpenSettings = onOpenSettings
        applyLayoutBehavior(to: splitViewController, coordinator: context.coordinator)
    }

    private func applyLayoutBehavior(to splitViewController: UISplitViewController, coordinator: Coordinator) {
        let isCompact = actualHorizontalSizeClass == .compact
        guard coordinator.lastIsCompact != isCompact else { return }
        coordinator.lastIsCompact = isCompact

        if isCompact {
            splitViewController.traitOverrides.horizontalSizeClass = .regular
            splitViewController.preferredSplitBehavior = .overlay
            coordinator.secondaryHosting?.traitOverrides.horizontalSizeClass = .compact
        } else {
            splitViewController.traitOverrides.horizontalSizeClass = .unspecified
            splitViewController.preferredSplitBehavior = .automatic
            coordinator.secondaryHosting?.traitOverrides.horizontalSizeClass = .unspecified
        }
    }

    final class Coordinator: NSObject, UISplitViewControllerDelegate {
        let splitState: TerminalSplitPresentationState
        var onOpenSettings: () -> Void
        weak var splitViewController: UISplitViewController?
        weak var primaryHosting: UIViewController?
        weak var secondaryHosting: UIViewController?
        var lastIsCompact: Bool?

        init(splitState: TerminalSplitPresentationState, onOpenSettings: @escaping () -> Void) {
            self.splitState = splitState
            self.onOpenSettings = onOpenSettings
        }

        func hideSidebarIfOverlay() {
            guard let svc = splitViewController, svc.splitBehavior == .overlay else { return }
            svc.hide(.primary)
        }

        func splitViewController(
            _: UISplitViewController,
            willChangeTo displayMode: UISplitViewController.DisplayMode
        ) {
            splitState.isSidebarOverlayVisible = (displayMode == .oneOverSecondary || displayMode == .twoOverSecondary)
        }

        func splitViewController(_ svc: UISplitViewController, willShow column: UISplitViewController.Column) {
            if column == .primary, svc.splitBehavior == .overlay {
                splitState.isSidebarOverlayVisible = true
            }
        }

        func splitViewController(_ svc: UISplitViewController, willHide column: UISplitViewController.Column) {
            if column == .primary, svc.splitBehavior == .overlay {
                splitState.isSidebarOverlayVisible = false
            }
        }
    }
}

private struct TerminalDetailView: View {
    let sessionManager: TerminalSessionManager
    let splitState: TerminalSplitPresentationState
    let onSetupCallbacks: (TerminalSession) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                let isSelected = session.id == sessionManager.activeSessionID
                TerminalSessionContentView(
                    session: session,
                    isActive: isSelected && splitState.isTerminalInputActive && session.phase == .running,
                    isVisible: isSelected
                ) {
                    sessionManager.closeSession(id: session.id)
                }
                .opacity(isSelected ? 1 : 0)
                .zIndex(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .onAppear {
                    onSetupCallbacks(session)
                }
            }
        }
        .navigationTitle(horizontalSizeClass == .regular ? "" : (sessionManager.activeSession?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if horizontalSizeClass == .regular {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        TerminalTabBar(
                            sessions: sessionManager.sessions,
                            activeSessionID: sessionManager.activeSessionID,
                            onSelect: { sessionManager.activeSessionID = $0 },
                            onClose: { sessionManager.closeSession(id: $0) }
                        )
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        TerminalTabBar(
                            sessions: sessionManager.sessions,
                            activeSessionID: sessionManager.activeSessionID,
                            onSelect: { sessionManager.activeSessionID = $0 },
                            onClose: { sessionManager.closeSession(id: $0) }
                        )
                    }
                }
            }
        }
    }
}

private struct TerminalKeyboardShortcuts: View {
    let onNewSession: () -> Void
    let onCloseSession: () -> Void
    let onPreviousSession: () -> Void
    let onNextSession: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            Button("New Session", action: onNewSession)
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab", action: onNewSession)
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Session", action: onCloseSession)
                .keyboardShortcut("w", modifiers: .command)
            Button("Previous Session", action: onPreviousSession)
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Session", action: onNextSession)
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Settings", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
