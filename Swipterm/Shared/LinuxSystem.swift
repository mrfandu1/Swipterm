import Foundation
import Observation
import SwiptermKit
import UIKit

@Observable
final class LinuxSystem {
    enum State: Equatable {
        case checking
        case setup
        case provisioning(Provisioning)
        case booting
        case running
        case halted
        case failed(String)

        var keepsScreenAwake: Bool {
            if case let .provisioning(provisioning) = self {
                return provisioning.failure == nil
            }
            return false
        }
    }

    struct Provisioning: Equatable {
        let attempt: Int
        var failure: String?
    }

    struct InstallRequest: Sendable {
        enum Source: Sendable {
            case catalog(LinuxReleaseImage, mirror: DistributionMirror?)
            case localArchive(URL)
            case remoteArchive(URL)
        }

        let source: Source
        let containerName: String
        let initMode: ContainerInitMode
        let user: String
        let password: String?
        let software: ContainerSoftware
    }

    struct SessionHandle: Sendable {
        let terminal: LinuxTerminal
        let process: LinuxProcess
    }

    private struct ConsoleProgress {
        var fraction: Double?
        var detail: String?
        var chunkIndex: Int?
        var lineLength = 0
    }

    private enum StartupError: LocalizedError {
        case exited(Int32)
        case signaled(Int32)
        case halted

        var errorDescription: String? {
            switch self {
            case let .exited(code):
                String(localized: "Initialization failed with exit status \(code).")
            case let .signaled(signal):
                String(localized: "Initialization was terminated by signal \(signal).")
            case .halted:
                String(localized: "The container stopped during initialization.")
            }
        }
    }

    static let shared = LinuxSystem()

    private static let loginTimeout = Duration.seconds(300)
    private static let systemTimeout = Duration.seconds(120)
    private static let outputDrainTimeout = Duration.seconds(1)
    private static let haltReasonTimeout = Duration.seconds(5)
    private static let maxBootReboots = 2
    private static let consoleByteCountStyle = ByteCountFormatStyle(
        style: .file,
        spellsOutZero: false,
        locale: Locale(identifier: "en_US_POSIX")
    )

    private(set) var state: State = .checking
    private(set) var installedContainer: ContainerMetadata?
    private(set) var activeInitMode: ContainerInitMode?
    var onWillShutdown: (() -> Void)?

    private var runtime: LinuxRuntime?
    @ObservationIgnored private var consoleChunks: [Data] = []
    @ObservationIgnored private var consoleListeners: [UUID: (Data) -> Void] = [:]
    @ObservationIgnored private var runningWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var setupTerminal: LinuxTerminal?
    @ObservationIgnored private var setupTerminalSize = LinuxTerminal.Size(columns: 40, rows: 24)
    @ObservationIgnored private var haltedDuringProvisioning = false
    @ObservationIgnored private var awaitingBootReadiness = false
    @ObservationIgnored private var bootHalt: LinuxRuntime.HaltReason?
    @ObservationIgnored private var bootHaltWaiter: (boot: UInt64, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var bootCount: UInt64 = 0
    @ObservationIgnored private var runtimeBoot: UInt64 = 0
    @ObservationIgnored private var openConsoleProgress: ConsoleProgress?
    @ObservationIgnored private var consoleProgressEpoch: UInt64 = 0
    @ObservationIgnored private var pendingInstall: InstallRequest?
    private var provisioningAttempt = 0
    private var bootstrapped = false
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var pendingTeardown: Task<Void, Never>?
    private var isSuspended = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        observeApplicationLifecycle()
    }

    var consoleText: String {
        ConsoleText.plain(consoleChunks)
    }

    var hasConsoleOutput: Bool {
        !consoleChunks.isEmpty
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        requestLocalNetworkAuthorizationIfNeeded()

        let generation = beginOperation()
        activeTask = Task {
            let existing = await Task.detached { () -> ContainerMetadata? in
                Self.moveToTrash(Self.downloadStagingDirectoryURL)
                for item in Self.items(in: Self.rootDirectoryURL.deletingLastPathComponent(), withPrefix: Self.stagingRootPrefix) {
                    Self.moveToTrash(item, as: Self.rootDirectoryURL)
                }
                guard LinuxRootImage.isInstalled(at: Self.rootDirectoryURL), let metadata = Self.loadContainerMetadata() else {
                    Self.moveToTrash(Self.rootDirectoryURL)
                    return nil
                }
                return metadata
            }.value
            tearDownInBackground(nil)

            guard self.generation == generation else { return }
            guard let metadata = existing else {
                installedContainer = nil
                activeInitMode = nil
                state = .setup
                return
            }

            installedContainer = metadata
            if metadata.setupCompleted {
                await bootInstalledRoot(metadata: metadata, generation: generation)
            } else {
                beginSetupAttempt()
                await provision(metadata, generation: generation)
            }
        }
    }

    func install(_ request: InstallRequest) {
        let generation = beginOperation()
        pendingInstall = request
        beginSetupAttempt()
        switch request.source {
        case let .catalog(release, _):
            appendConsoleStep("Downloading \(release.distribution.displayName) \(release.displayTitle)", generation: generation)
        case let .remoteArchive(url):
            appendConsoleStep("Downloading \(url.lastPathComponent)", generation: generation)
        case let .localArchive(url):
            appendConsoleStep("Copying \(url.lastPathComponent)", generation: generation)
        }
        let previousRuntime = detachRuntimeForShutdown()

        activeTask = Task {
            if let previousRuntime {
                await shutDownRuntime(previousRuntime)
            }
            guard self.generation == generation else { return }

            let metadata = Self.makeMetadata(for: request)
            let stagingRootURL = Self.rootDirectoryURL.deletingLastPathComponent()
                .appending(path: Self.stagingRootPrefix + UUID().uuidString, directoryHint: .isDirectory)
            var placedRoot = false
            var temporaryArchiveURL: URL?
            defer {
                if let temporaryArchiveURL {
                    try? FileManager.default.removeItem(at: temporaryArchiveURL)
                }
                if !placedRoot {
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: stagingRootURL)
                    }
                }
            }

            do {
                let archiveURL: URL
                switch request.source {
                case let .catalog(release, mirror):
                    let candidates = DistributionMirrorRouter.candidates(
                        for: release.distribution.repository,
                        preferring: mirror
                    ) { endpoint in
                        endpoint.url(for: release.artifactPath)
                    }
                    var candidateFailure: (any Error)?
                    archiveURL = try await DistributionMirrorRouter.firstSuccess(of: candidates) { candidate in
                        if let candidateFailure {
                            endConsoleProgressLine(generation: generation)
                            appendConsole(
                                Data("\u{1B}[1;33mwarning:\u{1B}[0m \(candidateFailure.localizedDescription)\r\n".utf8),
                                generation: generation
                            )
                            appendConsoleStep(
                                "Retrying from \(candidate.url.host() ?? candidate.url.absoluteString)",
                                generation: generation
                            )
                        }
                        let epoch = consoleProgressEpoch
                        do {
                            return try await RootImageDownloader.download(
                                from: candidate.url,
                                expectedBytes: release.compressedBytes,
                                expectedSHA256: release.sha256,
                                onProgress: { progress in
                                    DispatchQueue.main.async {
                                        MainActor.assumeIsolated {
                                            LinuxSystem.shared.appendConsoleDownloadProgress(progress, generation: generation, epoch: epoch)
                                        }
                                    }
                                },
                                onVerifying: {
                                    DispatchQueue.main.async {
                                        MainActor.assumeIsolated {
                                            LinuxSystem.shared.appendConsoleStep("Verifying SHA-256", generation: generation)
                                        }
                                    }
                                }
                            )
                        } catch {
                            candidateFailure = error
                            throw error
                        }
                    }
                    temporaryArchiveURL = archiveURL

                case let .remoteArchive(url):
                    let epoch = consoleProgressEpoch
                    archiveURL = try await RootImageDownloader.download(
                        from: url,
                        onProgress: { progress in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    LinuxSystem.shared.appendConsoleDownloadProgress(progress, generation: generation, epoch: epoch)
                                }
                            }
                        },
                        onVerifying: {}
                    )
                    temporaryArchiveURL = archiveURL

                case let .localArchive(url):
                    let staged = try await Task.detached {
                        try Self.stageLocalArchive(from: url)
                    }.value
                    archiveURL = staged
                    temporaryArchiveURL = staged
                }

                guard self.generation == generation else { return }
                appendConsoleStep("Extracting root filesystem", generation: generation)
                let epoch = consoleProgressEpoch
                try await LinuxRootImage.archive(at: archiveURL).install(to: stagingRootURL) { fraction in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            LinuxSystem.shared.appendConsoleProgress(fraction: fraction, detail: nil, generation: generation, epoch: epoch)
                        }
                    }
                }
                guard self.generation == generation else { return }
                appendConsoleProgress(fraction: 1, detail: nil, generation: generation, epoch: epoch)
                endConsoleProgressLine(generation: generation)
                try? FileManager.default.removeItem(at: archiveURL)
                temporaryArchiveURL = nil

                try await Task.detached {
                    try Self.saveContainerMetadata(metadata, root: stagingRootURL)
                }.value
                guard self.generation == generation else { return }
                let fm = FileManager.default
                if fm.fileExists(atPath: Self.rootDirectoryURL.path(percentEncoded: false)) {
                    try fm.moveItem(at: Self.rootDirectoryURL, to: Self.trashURL(for: Self.rootDirectoryURL))
                }
                try fm.moveItem(at: stagingRootURL, to: Self.rootDirectoryURL)
                placedRoot = true
                tearDownInBackground(nil)
                pendingInstall = nil
                await provision(metadata, generation: generation)
            } catch is CancellationError {
                guard self.generation == generation else { return }
                pendingInstall = nil
                resetConsole()
                state = .setup
            } catch {
                guard self.generation == generation else { return }
                tearDownInBackground(nil)
                endConsoleProgressLine(generation: generation)
                appendConsole(Data("\u{1B}[1;31merror:\u{1B}[0m \(error.localizedDescription)\r\n".utf8), generation: generation)
                state = .provisioning(Provisioning(attempt: provisioningAttempt, failure: error.localizedDescription))
            }
        }
    }

    func retrySetup() {
        guard case let .provisioning(provisioning) = state, provisioning.failure != nil else { return }
        if let pendingInstall {
            install(pendingInstall)
        } else {
            restart()
        }
    }

    func updateInitMode(_ initMode: ContainerInitMode) {
        guard var metadata = installedContainer ?? Self.loadContainerMetadata(),
              metadata.initMode != initMode
        else {
            return
        }
        metadata.initMode = initMode
        installedContainer = metadata
        try? Self.saveContainerMetadata(metadata)
    }

    func restart() {
        guard let metadata = installedContainer ?? Self.loadContainerMetadata() else {
            state = .setup
            return
        }
        let generation = beginOperation()
        installedContainer = metadata
        if metadata.setupCompleted {
            resetConsole()
            state = .booting
        } else {
            beginSetupAttempt()
        }
        let previousRuntime = detachRuntimeForShutdown()
        activeTask = Task {
            if let previousRuntime {
                await shutDownRuntime(previousRuntime)
            }
            guard self.generation == generation else { return }
            if metadata.setupCompleted {
                await bootInstalledRoot(metadata: metadata, generation: generation)
            } else {
                await provision(metadata, generation: generation)
            }
        }
    }

    func reset() {
        _ = beginOperation()
        pendingInstall = nil
        let previousRuntime = detachRuntimeForShutdown()
        Self.moveToTrash(Self.rootDirectoryURL)
        Self.moveToTrash(Self.downloadStagingDirectoryURL)
        tearDownInBackground(previousRuntime)
        installedContainer = nil
        activeInitMode = nil
        resetConsole()
        state = .setup
    }

    func subscribeConsole(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        for chunk in consoleChunks {
            handler(chunk)
        }
        if acceptsConsoleOutput {
            consoleListeners[id] = handler
        }
        return id
    }

    func unsubscribeConsole(_ id: UUID) {
        consoleListeners.removeValue(forKey: id)
    }

    func resizeSetupTerminal(columns: UInt16, rows: UInt16) {
        let size = LinuxTerminal.Size(columns: max(columns, 1), rows: max(rows, 1))
        guard size != setupTerminalSize else { return }
        let previousColumns = setupTerminalSize.columns
        setupTerminalSize = size
        setupTerminal?.resize(size)
        guard let openConsoleProgress, size.columns != previousColumns else { return }
        let cursorRow = openConsoleProgress.lineLength / Int(size.columns)
        if cursorRow > 0 {
            let clear = Data(("\r\u{1B}[K" + String(repeating: "\u{1B}[A\r\u{1B}[K", count: cursorRow)).utf8)
            for listener in consoleListeners.values {
                listener(clear)
            }
        }
        renderConsoleProgress()
    }

    func waitUntilRunning() async throws {
        if state == .running {
            return
        }
        guard state == .booting else {
            throw CancellationError()
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if state == .running {
                    continuation.resume()
                } else if state != .booting {
                    continuation.resume(throwing: CancellationError())
                } else {
                    runningWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.runningWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func openSession(columns: UInt16, rows: UInt16) async throws -> SessionHandle {
        guard let runtime, state == .running else {
            throw LinuxError.ESRCH
        }
        let terminal = try runtime.makeTerminal(size: LinuxTerminal.Size(columns: columns, rows: rows))
        do {
            let process = try await runtime.login(user: installedContainer?.defaultUser ?? "root", on: terminal, environment: [
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "LANG": "C.UTF-8",
                "TZ": TimeZone.current.identifier,
                "BROWSER": "/run/host-bin/xdg-open",
            ])
            return SessionHandle(terminal: terminal, process: process)
        } catch {
            terminal.close()
            throw error
        }
    }

    private var acceptsConsoleOutput: Bool {
        switch state {
        case .booting:
            true
        case let .provisioning(provisioning):
            provisioning.failure == nil
        default:
            false
        }
    }

    private func beginOperation() -> UInt64 {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        cancelRunningWaiters()
        return generation
    }

    private func beginSetupAttempt() {
        provisioningAttempt += 1
        resetConsole()
        state = .provisioning(Provisioning(attempt: provisioningAttempt))
    }

    private func resetConsole() {
        consoleChunks.removeAll()
        consoleListeners.removeAll()
        openConsoleProgress = nil
        consoleProgressEpoch &+= 1
    }

    private func appendConsoleStep(_ title: String, generation: UInt64) {
        endConsoleProgressLine(generation: generation)
        appendConsole(Data("\u{1B}[1m==> \(title)\u{1B}[0m\r\n".utf8), generation: generation)
    }

    private func appendConsoleDownloadProgress(_ progress: RootImageDownloadProgress, generation: UInt64, epoch: UInt64) {
        var detail = progress.bytesWritten.formatted(Self.consoleByteCountStyle)
        if let totalBytes = progress.totalBytes, totalBytes > 0 {
            detail += " / \(totalBytes.formatted(Self.consoleByteCountStyle))"
        }
        appendConsoleProgress(fraction: progress.fraction, detail: detail, generation: generation, epoch: epoch)
    }

    private func appendConsoleProgress(fraction: Double?, detail: String?, generation: UInt64, epoch: UInt64) {
        guard self.generation == generation, consoleProgressEpoch == epoch else { return }
        var progress = openConsoleProgress ?? ConsoleProgress()
        progress.fraction = fraction
        progress.detail = detail
        openConsoleProgress = progress
        renderConsoleProgress()
    }

    private func renderConsoleProgress() {
        guard var progress = openConsoleProgress else { return }
        let line = ConsoleProgressLine.render(
            fraction: progress.fraction,
            detail: progress.detail,
            width: Int(setupTerminalSize.columns) - 1
        )
        let chunk = Data("\r\u{1B}[K\(line)".utf8)
        if let chunkIndex = progress.chunkIndex {
            consoleChunks[chunkIndex] = chunk
        } else {
            progress.chunkIndex = consoleChunks.count
            consoleChunks.append(chunk)
        }
        progress.lineLength = line.count
        openConsoleProgress = progress
        for listener in consoleListeners.values {
            listener(chunk)
        }
    }

    private func endConsoleProgressLine(generation: UInt64) {
        guard self.generation == generation else { return }
        consoleProgressEpoch &+= 1
        guard openConsoleProgress != nil else { return }
        openConsoleProgress = nil
        appendConsole(Data("\r\n".utf8), generation: generation)
    }

    private func cancelRunningWaiters() {
        let waiters = runningWaiters
        runningWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func completeRunningWaiters() {
        let waiters = runningWaiters
        runningWaiters.removeAll()
        consoleListeners.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func detachRuntimeForShutdown() -> LinuxRuntime? {
        onWillShutdown?()
        setupTerminal?.close()
        setupTerminal = nil
        let current = runtime
        runtime = nil
        return current
    }

    private func shutDownRuntime(_ target: LinuxRuntime) async {
        if isSuspended {
            isSuspended = false
            target.resume()
        }
        await Task.detached {
            target.shutdown()
        }.value
    }

    private func shutDownDetachedRuntime() async {
        if let previousRuntime = detachRuntimeForShutdown() {
            await shutDownRuntime(previousRuntime)
        }
    }

    private func tearDownInBackground(_ target: LinuxRuntime?) {
        if let target {
            let previousTeardown = pendingTeardown
            pendingTeardown = Task {
                await previousTeardown?.value
                await shutDownRuntime(target)
            }
        }
        let teardown = pendingTeardown
        Task.detached(priority: .utility) {
            await teardown?.value
            Self.emptyTrash()
        }
    }

    private func startRuntime(
        _ metadata: ContainerMetadata,
        initMode: ContainerInitMode,
        kernel: LinuxRuntime.Configuration.Kernel,
        writesHostname: Bool,
        generation: UInt64
    ) async throws -> LinuxRuntime {
        await pendingTeardown?.value
        guard self.generation == generation else { throw CancellationError() }
        bootCount &+= 1
        let boot = bootCount
        let normalizer = ConsoleNewlineNormalizer()
        let configuration = LinuxRuntime.Configuration(
            root: Self.rootDirectoryURL,
            initMode: initMode.runtimeInitMode,
            kernel: kernel,
            hostname: metadata.name,
            consoleOutput: { data in
                let chunk = normalizer.normalize(data)
                guard !chunk.isEmpty else { return }
                Task { @MainActor in
                    LinuxSystem.shared.appendConsole(chunk, generation: generation)
                }
            },
            haltHandler: { reason in
                Task { @MainActor in
                    LinuxSystem.shared.runtimeDidHalt(reason, generation: generation, boot: boot)
                }
            }
        )
        let hostname = writesHostname ? metadata.name : nil
        let bootedRuntime = try await LinuxRuntime.boot(configuration) { runtime in
            try await Self.prepareGuestEnvironment(runtime, hostname: hostname)
        }
        guard self.generation == generation else {
            tearDownInBackground(bootedRuntime)
            throw CancellationError()
        }
        runtime = bootedRuntime
        runtimeBoot = boot
        if isSuspended {
            bootedRuntime.suspend()
        }
        return bootedRuntime
    }

    private func bootInstalledRoot(metadata: ContainerMetadata, generation: UInt64) async {
        consoleChunks.removeAll()
        activeInitMode = metadata.initMode
        state = .booting
        do {
            var bootedBundled = true
            do {
                try await bootRoot(metadata, kernel: .installed, generation: generation, bootedBundled: &bootedBundled)
            } catch where !bootedBundled && !(error is CancellationError) && self.generation == generation {
                await shutDownDetachedRuntime()
                guard self.generation == generation else { return }
                appendConsole(Data((
                    "\r\n\u{1B}[1;31merror:\u{1B}[0m \(error.localizedDescription)\r\n" +
                        "\u{1B}[1m==> Retrying with the built-in kernel\u{1B}[0m\r\n"
                ).utf8), generation: generation)
                try await bootRoot(metadata, kernel: .bundled, generation: generation, bootedBundled: &bootedBundled)
            }
            state = .running
            completeRunningWaiters()
        } catch is CancellationError {
            guard self.generation == generation else { return }
            cancelRunningWaiters()
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            state = .setup
        } catch {
            guard self.generation == generation else { return }
            cancelRunningWaiters()
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func bootRoot(
        _ metadata: ContainerMetadata,
        kernel: LinuxRuntime.Configuration.Kernel,
        generation: UInt64,
        bootedBundled: inout Bool
    ) async throws {
        var reboots = 0
        while true {
            let bootedRuntime = try await startRuntime(
                metadata,
                initMode: metadata.initMode,
                kernel: kernel,
                writesHostname: false,
                generation: generation
            )
            let boot = runtimeBoot
            let bootedKernel = bootedRuntime.bootedKernel
            bootedBundled = bootedKernel.isBundled
            var log = "\u{1B}[1m==> Linux \(bootedKernel.release)\(bootedKernel.isBundled ? " (built-in)" : "")\u{1B}[0m\r\n"
            if let fallbackReason = bootedKernel.fallbackReason {
                log += "\u{1B}[1;33mwarning:\u{1B}[0m \(fallbackReason)\r\n"
            }
            appendConsole(Data(log.utf8), generation: generation)

            awaitingBootReadiness = true
            bootHalt = nil
            defer {
                if self.generation == generation {
                    awaitingBootReadiness = false
                }
            }
            var halted = false
            do {
                try await bootedRuntime.waitReady(.login, timeout: Self.loginTimeout)
            } catch let error as LinuxError where error == .ESRCH {
                halted = true
                await waitForBootHalt(boot)
            }
            guard self.generation == generation else { throw CancellationError() }
            if !halted, bootHalt == nil {
                if metadata.sshPort != nil, metadata.initMode == .managed {
                    _ = try? await bootedRuntime.spawn(LinuxProcess.Configuration(
                        executablePath: "/bin/sh",
                        arguments: ["-c", "install -d -m 0755 /run/sshd && ssh-keygen -A >/dev/null 2>&1 || true; exec \"$(command -v sshd)\""]
                    ))
                    guard self.generation == generation else { throw CancellationError() }
                }
                if bootHalt == nil {
                    return
                }
            }
            guard bootHalt == .reboot, reboots < Self.maxBootReboots else { throw StartupError.halted }
            reboots += 1
            await shutDownDetachedRuntime()
            guard self.generation == generation else { throw CancellationError() }
            appendConsole(Data("\r\n\u{1B}[1m==> Rebooting\u{1B}[0m\r\n".utf8), generation: generation)
        }
    }

    private func waitForBootHalt(_ boot: UInt64) async {
        guard bootHalt == nil else { return }
        let timeout = Task {
            try? await Task.sleep(for: Self.haltReasonTimeout)
            resumeBootHaltWaiter(boot)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                bootHaltWaiter = (boot, continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.resumeBootHaltWaiter(boot)
            }
        }
        timeout.cancel()
    }

    private func resumeBootHaltWaiter(_ boot: UInt64) {
        guard let waiter = bootHaltWaiter, waiter.boot == boot else { return }
        bootHaltWaiter = nil
        waiter.continuation.resume()
    }

    private func provision(_ metadata: ContainerMetadata, generation: UInt64) async {
        haltedDuringProvisioning = false
        installedContainer = metadata
        var metadata = metadata
        do {
            var setupMode: ContainerInitMode = metadata.distribution?.requiresSystemInit == true ? .system : .managed
            var (runtime, release) = try await bootForProvisioning(metadata, initMode: setupMode, generation: generation)
            if setupMode == .managed, release?.distribution?.requiresSystemInit == true {
                await shutDownDetachedRuntime()
                setupMode = .system
                (runtime, release) = try await bootForProvisioning(metadata, initMode: setupMode, generation: generation)
            }
            if metadata.distributionID == nil {
                if let detected = release?.distribution {
                    metadata.distributionID = detected.rawValue
                } else {
                    metadata.sshPort = nil
                }
            }
            if metadata.systemInit == nil {
                metadata.systemInit = await Self.systemInit(in: runtime.fileSystem, distribution: metadata.distribution)
            }
            if let requiredInitMode = metadata.systemInit?.requiredInitMode {
                metadata.initMode = requiredInitMode
            }

            let terminal = try runtime.makeTerminal(size: setupTerminalSize)
            setupTerminal = terminal
            let output = Task.detached {
                for await chunk in terminal.output {
                    await LinuxSystem.shared.appendConsole(chunk, generation: generation)
                }
            }
            let request = ContainerProvisioner.Request(
                hostname: metadata.name,
                user: metadata.defaultUser,
                password: metadata.setup?.password,
                mirrorID: metadata.setup?.mirrorID,
                software: metadata.setup?.software ?? ContainerSoftware()
            )
            let termination: LinuxProcess.Termination
            do {
                let process = try await ContainerProvisioner.start(
                    on: runtime,
                    terminal: terminal,
                    request: request,
                    release: release
                ) { text in
                    await LinuxSystem.shared.appendConsole(Data(text.utf8), generation: generation)
                }
                termination = await process.termination
            } catch {
                terminal.close()
                await output.value
                throw error
            }
            let drainDeadline = Task {
                try? await Task.sleep(for: Self.outputDrainTimeout)
                terminal.close()
            }
            await output.value
            drainDeadline.cancel()
            terminal.close()
            if setupTerminal === terminal {
                setupTerminal = nil
            }

            guard self.generation == generation else { return }
            if haltedDuringProvisioning {
                throw StartupError.halted
            }
            switch termination {
            case .exited(0):
                break
            case let .exited(code):
                throw StartupError.exited(code)
            case let .signaled(signal):
                throw StartupError.signaled(signal.rawValue)
            }

            metadata.setupCompleted = true
            metadata.setup = nil
            let completed = metadata
            try await Task.detached {
                try Self.saveContainerMetadata(completed)
            }.value
            guard self.generation == generation else { return }
            installedContainer = completed

            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            await bootInstalledRoot(metadata: completed, generation: generation)
        } catch {
            guard self.generation == generation else { return }
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            let message = haltedDuringProvisioning && !(error is StartupError)
                ? StartupError.halted.localizedDescription
                : error.localizedDescription
            state = .provisioning(Provisioning(attempt: provisioningAttempt, failure: message))
        }
    }

    private func bootForProvisioning(
        _ metadata: ContainerMetadata,
        initMode: ContainerInitMode,
        generation: UInt64
    ) async throws -> (LinuxRuntime, OSRelease?) {
        activeInitMode = initMode
        let bootedRuntime = try await startRuntime(
            metadata,
            initMode: initMode,
            kernel: .bundled,
            writesHostname: true,
            generation: generation
        )
        do {
            try await bootedRuntime.waitReady(.login, timeout: Self.loginTimeout)
        } catch let error as LinuxError where error == .ESRCH {
            throw StartupError.halted
        }
        if initMode == .system {
            try? await bootedRuntime.waitReady(.system, timeout: Self.systemTimeout)
        }
        try Task.checkCancellation()
        return (bootedRuntime, await ContainerProvisioner.detectRelease(on: bootedRuntime))
    }

    private func appendConsole(_ chunk: Data, generation: UInt64) {
        guard self.generation == generation, acceptsConsoleOutput else { return }
        consoleChunks.append(chunk)
        for listener in consoleListeners.values {
            listener(chunk)
        }
    }

    private func runtimeDidHalt(_ reason: LinuxRuntime.HaltReason, generation: UInt64, boot: UInt64) {
        guard self.generation == generation, let runtime, runtimeBoot == boot else { return }
        if state == .booting, awaitingBootReadiness {
            bootHalt = reason
            resumeBootHaltWaiter(boot)
            return
        }
        if case .provisioning = state {
            haltedDuringProvisioning = true
            shutDownHaltedRuntime(runtime)
            return
        }
        switch reason {
        case .reboot:
            restart()
        case .powerOff, .exited:
            _ = beginOperation()
            state = .halted
            resetConsole()
            activeTask = shutDownHaltedRuntime(runtime)
        }
    }

    @discardableResult
    private func shutDownHaltedRuntime(_ halted: LinuxRuntime) -> Task<Void, Never> {
        onWillShutdown?()
        setupTerminal?.close()
        setupTerminal = nil
        return Task {
            await shutDownRuntime(halted)
            if runtime === halted {
                runtime = nil
            }
        }
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDidEnterBackground()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillEnterForeground()
                }
            },
        ]
    }

    private func handleDidEnterBackground() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Swipterm.LinuxRuntime") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspendRuntimeIfNeeded()
                self.endBackgroundTaskIfNeeded()
            }
        }
        if backgroundTaskID == .invalid {
            suspendRuntimeIfNeeded()
        }
    }

    private func handleWillEnterForeground() {
        endBackgroundTaskIfNeeded()
        if isSuspended {
            isSuspended = false
            runtime?.resume()
        } else {
            try? runtime?.syncDNS()
        }
    }

    private func suspendRuntimeIfNeeded() {
        guard !isSuspended else { return }
        isSuspended = true
        runtime?.suspend()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func requestLocalNetworkAuthorizationIfNeeded() {
        guard let url = URL(string: "https://captive.apple.com") else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
    }

    private nonisolated static var rootDirectoryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Root", directoryHint: .isDirectory)
    }

    private nonisolated static let containerMetadataName = "swipterm-machine.json"

    private nonisolated static var stagingRootPrefix: String {
        ".\(rootDirectoryURL.lastPathComponent).installing."
    }

    private nonisolated static var downloadStagingDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermDownloads", directoryHint: .isDirectory)
    }

    private nonisolated static func loadContainerMetadata() -> ContainerMetadata? {
        guard let data = try? Data(contentsOf: rootDirectoryURL.appending(path: containerMetadataName)) else { return nil }
        return try? JSONDecoder().decode(ContainerMetadata.self, from: data)
    }

    private nonisolated static func saveContainerMetadata(_ metadata: ContainerMetadata, root: URL = rootDirectoryURL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(
            to: root.appending(path: containerMetadataName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private nonisolated static func makeMetadata(for request: InstallRequest) -> ContainerMetadata {
        var release: LinuxReleaseImage?
        var mirrorID: String?
        if case let .catalog(catalogRelease, mirror) = request.source {
            release = catalogRelease
            mirrorID = mirror?.id
        }
        return ContainerMetadata(
            name: request.containerName,
            distributionID: release?.distribution.rawValue,
            distributionVariant: release?.variant,
            systemInit: release.flatMap { $0.distribution.systemInit(variant: $0.variant) },
            installedAt: Date(),
            initMode: request.initMode,
            defaultUser: request.user,
            setupCompleted: false,
            setup: ContainerSetup(mirrorID: mirrorID, password: request.password, software: request.software),
            sshPort: request.software.ssh?.port
        )
    }

    private nonisolated static func stageLocalArchive(from sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let stagingDir = downloadStagingDirectoryURL
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let destination = stagingDir.appending(path: "\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        try sourceURL.withSecurityScopedAccess {
            try fm.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    private nonisolated static func trashURL(for owner: URL) -> URL {
        owner.deletingLastPathComponent()
            .appending(path: ".\(owner.lastPathComponent).trash.\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private nonisolated static func moveToTrash(_ url: URL, as owner: URL? = nil) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        if (try? fm.moveItem(at: url, to: trashURL(for: owner ?? url))) == nil {
            try? fm.removeItem(at: url)
        }
    }

    private nonisolated static func emptyTrash() {
        for url in [rootDirectoryURL, downloadStagingDirectoryURL] {
            for item in items(in: url.deletingLastPathComponent(), withPrefix: ".\(url.lastPathComponent).trash.") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private nonisolated static func items(in directory: URL, withPrefix prefix: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private nonisolated static func systemInit(in fileSystem: LinuxFileSystem, distribution: LinuxDistribution?) async -> SystemInit {
        guard let initInode = try? await fileSystem.stat("/sbin/init").inode else { return .absent }
        for path in ["/usr/lib/systemd/systemd", "/lib/systemd/systemd"] {
            if (try? await fileSystem.stat(path).inode) == initInode {
                return .systemd
            }
        }
        for path in ["/bin/busybox", "/usr/bin/busybox"] {
            if (try? await fileSystem.stat(path).inode) == initInode {
                for openrc in ["/sbin/openrc", "/usr/bin/openrc"] {
                    if (try? await fileSystem.stat(openrc)) != nil {
                        return .other
                    }
                }
                return .absent
            }
        }
        return distribution == nil ? .absent : .other
    }

    private nonisolated static func prepareGuestEnvironment(_ runtime: LinuxRuntime, hostname: String?) async throws {
        if let hostname {
            try await runtime.fileSystem.writeFile("/etc/hostname", contents: Data("\(hostname)\n".utf8), permissions: 0o644)
        }
        do {
            try await runtime.registerDevice(at: "/dev/clipboard", handler: ClipboardDevice())
        } catch let error as LinuxError where error == .ENODEV {}
        for command in ["open", "xdg-open"] {
            try await runtime.registerCommand(named: command) { invocation in
                try await Self.handleOpenCommand(invocation, name: command)
            }
        }
    }

    private nonisolated static func handleOpenCommand(_ invocation: HostCommandInvocation, name: String) async throws -> Int32 {
        var target: String?
        var parsingOptions = true
        for argument in invocation.arguments {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions, argument.hasPrefix("-") {
                continue
            }
            target = argument
            break
        }
        guard let target else {
            try await invocation.standardError.write(Data("usage: \(name) <url>\n".utf8))
            return 2
        }
        guard let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty else {
            try await invocation.standardError.write(Data("\(name): invalid URL: \(target)\n".utf8))
            return 1
        }
        let opened = await Task { @MainActor in
            await UIApplication.shared.open(url)
        }.value
        if !opened {
            try await invocation.standardError.write(Data("\(name): failed to open \(target)\n".utf8))
            return 1
        }
        return 0
    }
}

private nonisolated extension ContainerInitMode {
    var runtimeInitMode: LinuxRuntime.Configuration.InitMode {
        switch self {
        case .managed: .managed
        case .system: .system
        }
    }
}
