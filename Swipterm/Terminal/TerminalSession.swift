import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import Observation
import SwiftUI
import SwiptermKit
import UserNotifications

@Observable
final class TerminalSession: Identifiable {
    enum Phase: Equatable {
        case starting
        case running
        case finished(EndReason)
    }

    enum EndReason: Equatable {
        case exited(code: Int32)
        case signaled(Int32)
        case failed(String)
    }

    let id = UUID()
    let number: Int
    let state: TerminalViewState
    let extras = TerminalExtras()
    /// Retain a single UITerminalView per session so Ghostty preserves grid and scrollback across layout detaches.
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var phase: Phase = .starting
    private(set) var hasVisibleOutput = false
    private(set) var backgroundColor: TerminalColor?

    @ObservationIgnored var onCleanExit: (() -> Void)?

    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let relay: TerminalRelay
    @ObservationIgnored private let startedAt = Date()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var notificationAuthorizationRequested = false
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(number: Int) {
        self.number = number
        let relay = TerminalRelay()
        self.relay = relay
        session = InMemoryTerminalSession(
            write: { data in
                relay.sendInput(data)
            },
            resize: { viewport in
                relay.resize(columns: UInt16(clamping: viewport.columns), rows: UInt16(clamping: viewport.rows))
            }
        )
        session.setOutputBacklogHandler(highWater: 4 << 20, lowWater: 1 << 20) { isBacklogged in
            relay.setOutputBacklogged(isBacklogged)
        }
        state = TerminalViewState(
            configSource: .none,
            theme: TerminalAppearance.theme(),
            terminalConfiguration: TerminalAppearance.fontConfiguration()
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        extras.state = state
        extras.alwaysShowsSymbolBar = AppSettings.shared.alwaysShowSymbolBar

        let view = TerminalSurfaceView.SurfaceView(frame: .zero)
        view.controller = state.controller
        view.configuration = state.configuration
        view.delegate = extras
        surfaceView = view

        extras.onDesktopNotification = { [weak self] title, body in
            self?.postSystemNotification(title: title, body: body)
        }
        state.$backgroundColor
            .sink { [weak self] color in
                self?.backgroundColor = color
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AppSettings.terminalAppearanceDidChange)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
    }

    var title: String {
        let trimmed = extras.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "Session \(number)") : trimmed
    }

    var workingDirectory: String {
        extras.workingDirectory
    }

    func beginStart() {
        startTask = Task {
            await start()
        }
    }

    func start() async {
        let session = session
        let relay = relay
        let firstPtyOutput = OnceFlag()
        var consoleSubscription: UUID?
        defer {
            if let consoleSubscription {
                LinuxSystem.shared.unsubscribeConsole(consoleSubscription)
            }
        }
        do {
            if LinuxSystem.shared.state == .booting {
                var showedBootConsole = false
                if number == 1 {
                    consoleSubscription = LinuxSystem.shared.subscribeConsole { [weak self] data in
                        guard !data.isEmpty else { return }
                        showedBootConsole = true
                        if self?.hasVisibleOutput == false {
                            self?.hasVisibleOutput = true
                        }
                        session.receive(data)
                    }
                }
                try await LinuxSystem.shared.waitUntilRunning()
                if let id = consoleSubscription {
                    LinuxSystem.shared.unsubscribeConsole(id)
                    consoleSubscription = nil
                }
                if showedBootConsole {
                    session.receive(Data("\u{1B}[0m\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8))
                }
            }
            guard !isClosed, !Task.isCancelled else { return }
            let size = relay.size
            let handle = try await LinuxSystem.shared.openSession(columns: size.columns, rows: size.rows)
            guard !isClosed, !Task.isCancelled else {
                handle.terminal.close()
                return
            }
            relay.attach(handle.terminal, openedWith: size)
            if phase == .starting {
                phase = .running
            }

            let terminal = handle.terminal
            let process = handle.process
            let inputStream = relay.inputStream
            let inputTask = Task.detached {
                for await data in inputStream {
                    await terminal.write(data)
                }
            }
            let outputTask = Task.detached { [weak self] in
                while let data = await terminal.read() {
                    await relay.waitWhileBacklogged()
                    guard !relay.isAborted else { break }
                    session.receive(data)
                    if firstPtyOutput.claim() {
                        Task { @MainActor [weak self] in
                            self?.hasVisibleOutput = true
                        }
                    }
                }
            }
            Task.detached { [weak self] in
                let termination = await process.termination
                terminal.close()
                relay.releaseBacklogForExit()
                await outputTask.value
                inputTask.cancel()
                await self?.didTerminate(termination)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isClosed, !Task.isCancelled else { return }
            phase = .finished(.failed(error.localizedDescription))
        }
    }

    func close() {
        isClosed = true
        startTask?.cancel()
        startTask = nil
        surfaceView.setSurfaceVisible(false)
        surfaceView.syncFocus(isActive: false)
        relay.abort()?.close()
    }

    private func didTerminate(_ termination: LinuxProcess.Termination) {
        guard !isClosed else { return }
        let runtime = UInt64(max(0, Date().timeIntervalSince(startedAt)) * 1000)
        switch termination {
        case let .exited(code):
            session.finish(exitCode: UInt32(code), runtimeMilliseconds: runtime)
            phase = .finished(.exited(code: code))
            if code == 0 {
                onCleanExit?()
            }
        case let .signaled(signal):
            session.finish(exitCode: UInt32(128 + signal.rawValue), runtimeMilliseconds: runtime)
            phase = .finished(.signaled(signal.rawValue))
        }
        relay.abort()?.close()
    }

    private func applySettings() {
        state.controller.setTheme(TerminalAppearance.theme())
        state.controller.setTerminalConfiguration(TerminalAppearance.fontConfiguration())
        extras.alwaysShowsSymbolBar = AppSettings.shared.alwaysShowSymbolBar
    }

    private func postSystemNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let requestAuthorization = !notificationAuthorizationRequested
        notificationAuthorizationRequested = true
        Task {
            if requestAuthorization {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            }
            try? await center.add(request)
        }
    }
}

enum TerminalAppearance {
    static func theme() -> TerminalTheme {
        let settings = AppSettings.shared
        return TerminalTheme(
            light: configuration(
                themeName: settings.lightTheme,
                customText: settings.lightConfig,
                fallback: .alabaster
            ),
            dark: configuration(
                themeName: settings.darkTheme,
                customText: settings.darkConfig,
                fallback: .afterglow
            )
        )
    }

    private static func configuration(
        themeName: String,
        customText: String,
        fallback: TerminalConfiguration
    ) -> TerminalConfiguration {
        guard !themeName.isEmpty else {
            return TerminalConfiguration { builder in
                for rawLine in customText.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
                    let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    builder.withCustom(key, value)
                }
            }
        }
        return GhosttyThemeCatalog.theme(named: themeName)?.toTerminalConfiguration() ?? fallback
    }

    static func fontConfiguration() -> TerminalConfiguration {
        let settings = AppSettings.shared
        let size = Float(settings.fontSize)
        let family = settings.fontFollowTheme ? "" : settings.fontFamily
        return TerminalConfiguration { builder in
            if !family.isEmpty {
                builder.withFontFamily(family)
            }
            builder.withFontSize(size)
        }
    }
}

private final nonisolated class TerminalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTerminal: LinuxTerminal?
    private var currentSize = LinuxTerminal.Size(columns: 80, rows: 24)
    private var backlogged = false
    private var aborted = false
    private var drainingExit = false
    private var backlogWaiter: CheckedContinuation<Void, Never>?

    let inputStream: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        inputStream = stream
        inputContinuation = continuation
    }

    var size: LinuxTerminal.Size {
        lock.withLock { currentSize }
    }

    var isAborted: Bool {
        lock.withLock { aborted }
    }

    func sendInput(_ data: Data) {
        let ready = lock.withLock { currentTerminal != nil && !aborted }
        if ready {
            inputContinuation.yield(data)
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        let size = LinuxTerminal.Size(columns: columns, rows: rows)
        let terminal = lock.withLock {
            currentSize = size
            return currentTerminal
        }
        terminal?.resize(size)
    }

    func setOutputBacklogged(_ isBacklogged: Bool) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            backlogged = isBacklogged
            guard !isBacklogged, let waiter = backlogWaiter else { return nil }
            backlogWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func waitWhileBacklogged() async {
        let needsWait = lock.withLock { backlogged && !aborted && !drainingExit }
        guard needsWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard backlogged, !aborted, !drainingExit else { return true }
                backlogWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func releaseBacklogForExit() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            drainingExit = true
            backlogged = false
            defer { backlogWaiter = nil }
            return backlogWaiter
        }
        waiter?.resume()
    }

    func attach(_ terminal: LinuxTerminal, openedWith size: LinuxTerminal.Size) {
        let currentSize = lock.withLock {
            currentTerminal = terminal
            return self.currentSize
        }
        if currentSize != size {
            terminal.resize(currentSize)
        }
    }

    func abort() -> LinuxTerminal? {
        inputContinuation.finish()
        let (terminal, waiter) = lock.withLock {
            aborted = true
            backlogged = false
            defer {
                currentTerminal = nil
                backlogWaiter = nil
            }
            return (currentTerminal, backlogWaiter)
        }
        waiter?.resume()
        return terminal
    }
}

private final nonisolated class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
