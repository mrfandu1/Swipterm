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
        var meter: ConsoleMeter
        var chunkIndex: Int?
        var lineLengths: [Int] = []
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
    private static let outputDrainTimeout = Duration.seconds(1)
    private static let haltReasonTimeout = Duration.seconds(5)
    private static let maxBootReboots = 2

    private(set) var state: State = .checking
    private(set) var installedContainer: ContainerMetadata?
    private(set) var activeInitMode: ContainerInitMode?
    var pendingOpenURL: URL?
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
        case .catalog, .remoteArchive:
            appendConsoleStep("Download", generation: generation)
        case .localArchive:
            appendConsoleStep("Copy", generation: generation)
        }
        let previousRuntime = detachRuntimeForShutdown()

        activeTask = Task {
            if let previousRuntime {
                await shutDownRuntime(previousRuntime)
            }
            guard self.generation == generation else { return }

            var metadata = Self.makeMetadata(for: request)
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
                    let urls = await DistributionMirrorRouter.endpoints(
                        for: release.distribution.repository,
                        preferring: mirror
                    ).map { $0.url(for: release.artifactPath) }
                    archiveURL = try await downloadArchive(
                        from: urls,
                        expectedBytes: release.compressedBytes,
                        generation: generation
                    )
                    temporaryArchiveURL = archiveURL

                case let .remoteArchive(url):
                    archiveURL = try await downloadArchive(from: [url], generation: generation)
                    temporaryArchiveURL = archiveURL

                case let .localArchive(url):
                    let staged = try await Task.detached {
                        try Self.stageLocalArchive(from: url)
                    }.value
                    archiveURL = staged
                    temporaryArchiveURL = staged
                }

                guard self.generation == generation else { return }
                appendConsoleStep("Extract", generation: generation)
                let builder = try LinuxRootImageBuilder(root: stagingRootURL)
                try await unpack(nil, generation: generation) { progress in
                    try await builder.add(.archive(at: archiveURL), progress: progress)
                }
                guard self.generation == generation else { return }
                try? FileManager.default.removeItem(at: archiveURL)
                temporaryArchiveURL = nil
                if case let .catalog(release, _) = request.source {
                    let packageMirrorID = try await installKernel(
                        release.distribution,
                        mirrorID: metadata.setup?.mirrorID,
                        into: builder,
                        generation: generation
                    )
                    metadata.setup?.packageMirrorID = packageMirrorID
                    guard self.generation == generation else { return }
                }
                try await builder.finish()
                guard self.generation == generation else { return }

                try await Task.detached { [metadata] in
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
        guard openConsoleProgress != nil, size.columns != previousColumns else { return }
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

    private func downloadArchive(
        from urls: [URL],
        expectedBytes: Int64? = nil,
        generation: UInt64
    ) async throws -> URL {
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        return try await RootImageDownloader.download(
            from: urls,
            expectedBytes: expectedBytes,
            onProgress: { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        LinuxSystem.shared.appendConsoleDownloadProgress(progress, start: start, generation: generation, epoch: epoch)
                    }
                }
            }
        )
    }

    private func installKernel(
        _ distribution: LinuxDistribution,
        mirrorID: String?,
        into builder: LinuxRootImageBuilder,
        generation: UInt64
    ) async throws -> String {
        guard let release = try Self.osRelease(in: builder) else {
            throw KernelBootstrapError.unknownRelease
        }
        appendConsoleStep("Kernel", generation: generation)
        let official = DistributionMirror.official
        let mirror = try await PackageMirrorResolver.resolve(for: distribution, release: release, mirrorID: mirrorID)
            ?? PackageMirror(id: official.id, name: official.name, root: official.packages[distribution]!)
        appendConsole(Data("    \(distribution.displayName): \(mirror.name) (\(mirror.root.url))\r\n".utf8), generation: generation)
        let directory = Self.downloadStagingDirectoryURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let bootstrap = KernelBootstrap(distribution: distribution, release: release, mirror: mirror)
        let packages = try await bootstrap.packages { url, expectedBytes in
            try await self.download(url, expectedBytes: expectedBytes, into: directory, generation: generation)
        }
        var files: [URL] = []
        for package in packages {
            try await files.append(download(package.url, expectedBytes: package.size, into: directory, generation: generation))
        }
        var installed: [KernelBootstrap.Installed] = []
        for (package, file) in zip(packages, files) {
            let contents = try await unpack(package.name, generation: generation) { progress in
                try await builder.addPackage(at: file, progress: progress)
            }
            installed.append(KernelBootstrap.Installed(package: package, file: file, contents: contents))
        }
        try await bootstrap.register(installed, in: builder)
        return mirror.id
    }

    private func download(
        _ url: URL,
        expectedBytes: Int64?,
        into directory: URL,
        generation: UInt64
    ) async throws -> URL {
        let name = url.lastPathComponent
        let destination = directory.appending(path: "\(UUID().uuidString)-\(name)")
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        defer {
            endConsoleProgressLine(generation: generation)
        }
        try await HTTPClient.download(
            from: [url],
            to: destination,
            expectedBytes: expectedBytes,
            progress: { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        LinuxSystem.shared.appendConsoleDownloadProgress(progress, name: name, start: start, generation: generation, epoch: epoch)
                    }
                }
            }
        )
        return destination
    }

    private func unpack<Result>(
        _ name: String?,
        generation: UInt64,
        _ body: (@escaping @Sendable (Double) -> Void) async throws -> Result
    ) async throws -> Result {
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        let result = try await body { fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LinuxSystem.shared.appendConsoleExtractionProgress(name, fraction, start: start, generation: generation, epoch: epoch)
                }
            }
        }
        appendConsoleExtractionProgress(name, 1, start: start, generation: generation, epoch: epoch)
        endConsoleProgressLine(generation: generation)
        return result
    }

    private func appendConsoleDownloadProgress(
        _ progress: HTTPDownloadProgress,
        name: String? = nil,
        start: ContinuousClock.Instant,
        generation: UInt64,
        epoch: UInt64
    ) {
        var meter = DownloadMeter(start: start, name: name)
        if case let .download(current)? = openConsoleProgress?.meter {
            meter = current
        }
        meter.update(progress)
        updateConsoleProgress(.download(meter), generation: generation, epoch: epoch)
    }

    private func appendConsoleExtractionProgress(
        _ name: String?,
        _ fraction: Double,
        start: ContinuousClock.Instant,
        generation: UInt64,
        epoch: UInt64
    ) {
        updateConsoleProgress(
            .extraction(name: name, fraction: fraction, elapsed: start.duration(to: .now)),
            generation: generation,
            epoch: epoch
        )
    }

    private func updateConsoleProgress(_ meter: ConsoleMeter, generation: UInt64, epoch: UInt64) {
        guard self.generation == generation, consoleProgressEpoch == epoch else { return }
        var progress = openConsoleProgress ?? ConsoleProgress(meter: meter)
        progress.meter = meter
        openConsoleProgress = progress
        renderConsoleProgress()
    }

    private func renderConsoleProgress() {
        guard var progress = openConsoleProgress else { return }
        let columns = Int(setupTerminalSize.columns)
        let lines = progress.meter.lines(width: max(columns - 1, 20))
        let snapshot = lines.joined(separator: "\r\n")
        let rows = progress.lineLengths.reduce(0) { $0 + max(($1 + columns - 1) / columns, 1) }
        let redraw = Data(("\r" + (rows > 1 ? "\u{1B}[\(rows - 1)A" : "") + "\u{1B}[J" + snapshot).utf8)
        if let chunkIndex = progress.chunkIndex {
            consoleChunks[chunkIndex] = Data(snapshot.utf8)
        } else {
            progress.chunkIndex = consoleChunks.count
            consoleChunks.append(Data(snapshot.utf8))
        }
        progress.lineLengths = lines.map(\.count)
        openConsoleProgress = progress
        for listener in consoleListeners.values {
            listener(redraw)
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
            try await bootRoot(metadata, generation: generation)
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
            state = .failed(Self.failureMessage(error))
        }
    }

    private func bootRoot(_ metadata: ContainerMetadata, generation: UInt64) async throws {
        var reboots = 0
        while true {
            let bootedRuntime = try await startRuntime(
                metadata,
                initMode: metadata.initMode,
                writesHostname: false,
                generation: generation
            )
            let boot = runtimeBoot
            appendBootedKernel(bootedRuntime.bootedKernel, generation: generation)

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
                if metadata.initMode == .managed {
                    await Self.startManagedServices(bootedRuntime, metadata: metadata)
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

    private func appendBootedKernel(_ kernel: LinuxRuntime.BootedKernel, generation: UInt64) {
        var log = "\u{1B}[1m==> Linux \(kernel.release)\u{1B}[0m\r\n"
        if let fallbackReason = kernel.fallbackReason {
            log += "\u{1B}[1;33mwarning:\u{1B}[0m \(fallbackReason.replacingOccurrences(of: "\n", with: "\r\n"))\r\n"
        }
        appendConsole(Data(log.utf8), generation: generation)
    }

    private nonisolated static func startManagedServices(_ runtime: LinuxRuntime, metadata: ContainerMetadata) async {
        guard metadata.sshPort != nil else { return }
        _ = try? await runtime.spawn(LinuxProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", "install -d -m 0755 /run/sshd && ssh-keygen -A >/dev/null 2>&1 || true; exec \"$(command -v sshd)\""]
        ))
    }

    private nonisolated static func failureMessage(_ error: any Error) -> String {
        guard let error = error as? LinuxRuntime.KernelUnavailableError else {
            return error.localizedDescription
        }
        let message = String(localized: "This system has no kernel that can boot on this device. Use an archive that includes a 4K-page ARM64 kernel.")
        return error.reasons.isEmpty ? message : message + "\n\n" + error.reasons.joined(separator: "\n")
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
            let (runtime, release) = try await bootForProvisioning(metadata, generation: generation)
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
                packageMirrorID: metadata.setup?.packageMirrorID,
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

            guard completed.initMode == activeInitMode else {
                await shutDownDetachedRuntime()
                guard self.generation == generation else { return }
                await bootInstalledRoot(metadata: completed, generation: generation)
                return
            }
            await Self.startManagedServices(runtime, metadata: completed)
            guard self.generation == generation else { return }
            state = .running
            completeRunningWaiters()
        } catch {
            guard self.generation == generation else { return }
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            let message = haltedDuringProvisioning && !(error is StartupError)
                ? StartupError.halted.localizedDescription
                : Self.failureMessage(error)
            state = .provisioning(Provisioning(attempt: provisioningAttempt, failure: message))
        }
    }

    private func bootForProvisioning(_ metadata: ContainerMetadata, generation: UInt64) async throws -> (LinuxRuntime, OSRelease?) {
        activeInitMode = .managed
        let bootedRuntime = try await startRuntime(
            metadata,
            initMode: .managed,
            writesHostname: true,
            generation: generation
        )
        appendBootedKernel(bootedRuntime.bootedKernel, generation: generation)
        do {
            try await bootedRuntime.waitReady(.login, timeout: Self.loginTimeout)
        } catch let error as LinuxError where error == .ESRCH {
            throw StartupError.halted
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
            systemInit: release?.distribution.systemInit,
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

    private nonisolated static func osRelease(in builder: LinuxRootImageBuilder) throws -> OSRelease? {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            if let data = try builder.contents(of: path) {
                return OSRelease(String(decoding: data, as: UTF8.self))
            }
        }
        return nil
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
        await MainActor.run {
            LinuxSystem.shared.pendingOpenURL = url
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
