import Foundation
import SwiptermKit

nonisolated enum RootImageDownloadError: LocalizedError, Sendable {
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            String(localized: "The downloaded archive is empty.")
        }
    }
}

nonisolated enum RootImageDownloader {
    static func download(
        from urls: [URL],
        expectedBytes: Int64? = nil,
        onProgress: @escaping @Sendable (HTTPDownloadProgress) -> Void
    ) async throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appending(path: "SwiptermDownloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: stagingDir.path(percentEncoded: false)
        )
        let destination = stagingDir.appending(path: "\(UUID().uuidString)\(archiveExtension(from: urls[0]))")
        do {
            try await HTTPClient.download(
                from: urls,
                to: destination,
                expectedBytes: expectedBytes,
                progress: onProgress
            )
            return destination
        } catch HTTPError.emptyBody {
            throw RootImageDownloadError.emptyFile
        }
    }

    private static func archiveExtension(from url: URL) -> String {
        let lower = url.lastPathComponent.lowercased()
        for suffix in [".tar.xz", ".tar.zst", ".tar.gz", ".tar.bz2", ".tgz", ".txz", ".tzst", ".tbz2", ".tar"] where lower.hasSuffix(suffix) {
            return suffix
        }
        return ".tar"
    }
}
