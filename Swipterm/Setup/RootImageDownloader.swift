import Foundation
import SwiptermKit

nonisolated enum RootImageDownloader {
    static func download(
        from url: URL,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ totalBytes: Int64?) -> Void
    ) async throws -> URL {
        let stagingDir = FileManager.default.temporaryDirectory
            .appending(path: "SwiptermDownloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: stagingDir.path(percentEncoded: false)
        )
        let destination = stagingDir.appending(path: "\(UUID().uuidString)\(archiveExtension(from: url))")
        do {
            try await HTTPClient.download(from: url, to: destination, progress: progress).requireSuccess()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
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
