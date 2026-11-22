import CryptoKit
import Foundation

nonisolated enum RootImageDownloadError: LocalizedError, Sendable {
    case insecureURL
    case httpStatus(Int)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .insecureURL:
            String(localized: "Only HTTPS image URLs are supported.")
        case let .httpStatus(code):
            "HTTP status \(code)"
        case let .contentLengthMismatch(expected, actual):
            "Content-Length mismatch: expected \(expected), got \(actual)"
        case let .checksumMismatch(expected, actual):
            "SHA-256 mismatch: expected \(expected), got \(actual)"
        case .emptyFile:
            String(localized: "Downloaded archive is empty.")
        }
    }
}

nonisolated struct RootImageDownloadProgress: Equatable, Sendable {
    let bytesWritten: Int64
    let totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }
}

nonisolated enum RootImageDownloader {
    static func download(
        from url: URL,
        expectedBytes: Int64? = nil,
        expectedSHA256: String? = nil,
        onProgress: @escaping @Sendable (RootImageDownloadProgress) -> Void,
        onVerifying: @escaping @Sendable () -> Void
    ) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else {
            throw RootImageDownloadError.insecureURL
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appending(path: "SwiptermDownloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = archiveExtension(from: url)
        let destination = stagingDir.appending(path: "\(UUID().uuidString)\(ext)")

        let delegate = DownloadDelegate(
            destination: destination,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256?.isEmpty == false ? expectedSHA256 : nil,
            onProgress: onProgress,
            onVerifying: onVerifying
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await delegate.start(with: session, url: url)
        } onCancel: {
            delegate.cancel()
        }
    }

    private static func archiveExtension(from url: URL) -> String {
        let lower = url.lastPathComponent.lowercased()
        for suffix in [".tar.xz", ".tar.gz", ".tar.bz2", ".tgz", ".txz", ".tbz2", ".tar"] where lower.hasSuffix(suffix) {
            return suffix
        }
        return ".tar"
    }
}

private final nonisolated class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let bufferCapacity = 1 << 20

    private let destination: URL
    private let expectedBytes: Int64?
    private let expectedSHA256: String?
    private let onProgress: @Sendable (RootImageDownloadProgress) -> Void
    private let onVerifying: @Sendable () -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var dataTask: URLSessionDataTask?
    private var cancelled = false

    private var failure: Error?
    private var fileDescriptor: Int32 = -1
    private var buffer: Data
    private var hasher: SHA256?
    private var bytesReceived: Int64 = 0
    private var totalBytes: Int64?
    private var lastReportTime: TimeInterval?

    init(
        destination: URL,
        expectedBytes: Int64?,
        expectedSHA256: String?,
        onProgress: @escaping @Sendable (RootImageDownloadProgress) -> Void,
        onVerifying: @escaping @Sendable () -> Void
    ) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.onProgress = onProgress
        self.onVerifying = onVerifying
        buffer = Data(capacity: Self.bufferCapacity)
        hasher = expectedSHA256 == nil ? nil : SHA256()
    }

    func start(with session: URLSession, url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDataTask? = lock.withLock {
                guard !cancelled else { return nil }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                dataTask = task
                return task
            }
            guard let task else {
                continuation.resume(throwing: CancellationError())
                return
            }
            task.resume()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            cancelled = true
            return dataTask
        }
        task?.cancel()
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            var request = request
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            completionHandler(request)
        } else {
            failure = RootImageDownloadError.insecureURL
            completionHandler(nil)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            buffer.removeAll(keepingCapacity: true)
            bytesReceived = 0
            lastReportTime = nil
            hasher = expectedSHA256 == nil ? nil : SHA256()
        }
        if failure == nil, let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            failure = RootImageDownloadError.httpStatus(http.statusCode)
        }
        if failure == nil, expectedSHA256 != nil, let expectedBytes, expectedBytes > 0,
           response.expectedContentLength > 0, response.expectedContentLength != expectedBytes
        {
            failure = RootImageDownloadError.contentLengthMismatch(
                expected: expectedBytes,
                actual: response.expectedContentLength
            )
        }
        guard failure == nil else {
            completionHandler(.cancel)
            return
        }
        let descriptor = destination.withUnsafeFileSystemRepresentation { path in
            open(path!, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            completionHandler(.cancel)
            return
        }
        fileDescriptor = descriptor
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : expectedBytes
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        hasher?.update(data: data)
        buffer.append(data)
        bytesReceived += Int64(data.count)
        if buffer.count >= Self.bufferCapacity {
            do {
                try flush()
            } catch {
                failure = error
                dataTask.cancel()
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let lastReportTime, now - lastReportTime < 0.1, bytesReceived != totalBytes {
            return
        }
        lastReportTime = now
        onProgress(RootImageDownloadProgress(bytesWritten: bytesReceived, totalBytes: totalBytes))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error>
        do {
            if lock.withLock({ cancelled }) {
                throw CancellationError()
            }
            if let failure {
                throw failure
            }
            if let error {
                throw error
            }
            guard fileDescriptor >= 0 else {
                throw URLError(.cannotOpenFile)
            }
            try flush()
            let descriptor = fileDescriptor
            fileDescriptor = -1
            guard close(descriptor) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard bytesReceived > 0 else {
                throw RootImageDownloadError.emptyFile
            }
            onProgress(RootImageDownloadProgress(bytesWritten: bytesReceived, totalBytes: totalBytes))
            if let hasher, let expectedSHA256 {
                onVerifying()
                let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                    throw RootImageDownloadError.checksumMismatch(expected: expectedSHA256, actual: actual)
                }
            }
            result = .success(destination)
        } catch {
            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }
            try? FileManager.default.removeItem(at: destination)
            result = .failure(error)
        }

        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            dataTask = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func flush() throws {
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                offset += written
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
