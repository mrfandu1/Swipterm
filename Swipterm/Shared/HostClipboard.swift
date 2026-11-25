import Foundation
import SwiptermKit
import UIKit
import UniformTypeIdentifiers

final nonisolated class HostClipboard: LinuxClipboard, @unchecked Sendable {
    static let shared = HostClipboard()

    private static let plainTextMIMEs = [
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "text/plain",
        "STRING",
        "TEXT",
    ]

    private let lock = NSLock()
    private weak var runtime: LinuxRuntime?
    private var lastObservedChangeCount = -1
    private var isWritingFromGuest = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIPasteboard.changedNotification,
            UIPasteboard.removedNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.syncOffers(force: false)
            }
        }
    }

    func attach(to runtime: LinuxRuntime) {
        lock.withLock {
            self.runtime = runtime
            lastObservedChangeCount = -1
        }
        syncOffers(force: true)
    }

    func detach(from runtime: LinuxRuntime?) {
        lock.withLock {
            if self.runtime === runtime || runtime == nil {
                self.runtime = nil
            }
        }
    }

    func syncOffers(force: Bool) {
        let pasteboard = UIPasteboard.general
        let target: LinuxRuntime? = lock.withLock {
            guard !isWritingFromGuest, let runtime else { return nil }
            let changeCount = pasteboard.changeCount
            if !force, changeCount == lastObservedChangeCount {
                return nil
            }
            lastObservedChangeCount = changeCount
            return runtime
        }
        guard let target else { return }
        let mimes = Self.offeredMIMETypes(from: pasteboard)
        try? target.setClipboardOffers(mimes)
    }

    func read(mime: String) throws -> Data? {
        let pasteboard = UIPasteboard.general
        if Self.plainTextMIMEs.contains(mime) || mime.hasPrefix("text/plain") {
            if pasteboard.hasStrings, let string = pasteboard.string {
                return Data(string.utf8)
            }
            if pasteboard.hasURLs, let url = pasteboard.url {
                return Data(url.absoluteString.utf8)
            }
            if let data = Self.loadProviderData(from: pasteboard.itemProviders, conformingTo: .plainText) {
                return data
            }
            return nil
        }

        if mime == "text/html" {
            if let data = Self.loadProviderData(from: pasteboard.itemProviders, conformingTo: .html) {
                return data
            }
            if let raw = pasteboard.data(forPasteboardType: UTType.html.identifier) {
                return raw
            }
            if let text = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String {
                return Data(text.utf8)
            }
            return nil
        }

        if mime == "image/png" {
            let providers = pasteboard.itemProviders
            if let png = Self.loadProviderData(from: providers, exactType: .png) {
                return png
            }
            if let png = pasteboard.data(forPasteboardType: UTType.png.identifier) {
                return png
            }
            if let rawImage = Self.loadProviderData(from: providers, conformingTo: .image),
               let image = UIImage(data: rawImage),
               let png = HostPasteStaging.normalizedPNGData(for: image)
            {
                return png
            }
            if let image = pasteboard.image, let png = HostPasteStaging.normalizedPNGData(for: image) {
                return png
            }
            return nil
        }

        let targetType: UTType? = switch mime {
        case "image/jpeg": .jpeg
        case "image/gif": .gif
        case "image/webp": .webP
        case "image/svg+xml": .svg
        default: nil
        }
        if let targetType {
            if let data = Self.loadProviderData(from: pasteboard.itemProviders, exactType: targetType) {
                return data
            }
            if let data = pasteboard.data(forPasteboardType: targetType.identifier) {
                return data
            }
            if targetType == .jpeg, let image = pasteboard.image {
                return image.jpegData(compressionQuality: 0.95)
            }
        }
        return nil
    }

    func write(_ items: [LinuxClipboardItem]) {
        let pasteboard = UIPasteboard.general
        var representation: [String: Any] = [:]
        for item in items {
            if Self.plainTextMIMEs.contains(item.mime) || item.mime.hasPrefix("text/plain") {
                if representation[UTType.utf8PlainText.identifier] == nil {
                    representation[UTType.utf8PlainText.identifier] = String(decoding: item.data, as: UTF8.self)
                }
            } else if item.mime == "text/html" {
                representation[UTType.html.identifier] = item.data
            } else if item.mime == "image/png" {
                representation[UTType.png.identifier] = item.data
            } else if item.mime == "image/jpeg" {
                representation[UTType.jpeg.identifier] = item.data
            } else if item.mime == "image/gif" {
                representation[UTType.gif.identifier] = item.data
            } else if item.mime == "image/webp" {
                representation[UTType.webP.identifier] = item.data
            } else if item.mime == "image/svg+xml" {
                representation[UTType.svg.identifier] = item.data
            }
        }

        if representation.isEmpty, !items.isEmpty {
            return
        }
        lock.withLock {
            isWritingFromGuest = true
        }
        pasteboard.items = representation.isEmpty ? [] : [representation]
        let updatedCount = pasteboard.changeCount
        lock.withLock {
            isWritingFromGuest = false
            lastObservedChangeCount = updatedCount
        }
    }

    static func writePlainTextFromDevice(_ text: String) {
        shared.write([LinuxClipboardItem(mime: "text/plain;charset=utf-8", data: Data(text.utf8))])
        let mimes = plainTextMIMEs
        let target = shared.lock.withLock { shared.runtime }
        try? target?.setClipboardOffers(mimes)
    }

    static func offeredMIMETypes(from pasteboard: UIPasteboard = .general) -> [String] {
        let types = pasteboard.types.compactMap(UTType.init)

        var mimes: [String] = []
        let hasText = pasteboard.hasStrings
            || pasteboard.hasURLs
            || types.contains { $0.conforms(to: .text) || $0.conforms(to: .url) }
        if hasText {
            mimes.append(contentsOf: plainTextMIMEs)
        }
        if types.contains(where: { $0.conforms(to: .html) }) {
            mimes.append("text/html")
        }
        let hasImage = pasteboard.hasImages || types.contains { $0.conforms(to: .image) }
        if hasImage {
            mimes.append("image/png")
            if types.contains(where: { $0.conforms(to: .jpeg) }) {
                mimes.append("image/jpeg")
            }
            if types.contains(where: { $0.conforms(to: .gif) }) {
                mimes.append("image/gif")
            }
            if types.contains(where: { $0.conforms(to: .webP) }) {
                mimes.append("image/webp")
            }
            if types.contains(where: { $0.conforms(to: .svg) }) {
                mimes.append("image/svg+xml")
            }
        }
        return mimes
    }

    private static func loadProviderData(from providers: [NSItemProvider], exactType: UTType) -> Data? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(exactType.identifier) {
            let matchesExact = provider.registeredTypeIdentifiers.contains { id in
                UTType(id) == exactType
            }
            if matchesExact, let data = loadDataSynchronously(from: provider, typeIdentifier: exactType.identifier) {
                return data
            }
        }
        return nil
    }

    private static func loadProviderData(from providers: [NSItemProvider], conformingTo target: UTType) -> Data? {
        for provider in providers {
            for identifier in provider.registeredTypeIdentifiers {
                guard let candidate = UTType(identifier), candidate.conforms(to: target) else { continue }
                if let data = loadDataSynchronously(from: provider, typeIdentifier: identifier) {
                    return data
                }
            }
        }
        return nil
    }

    private static func loadDataSynchronously(from provider: NSItemProvider, typeIdentifier: String) -> Data? {
        final class Box: @unchecked Sendable {
            var data: Data?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            box.data = data
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        return box.data
    }
}

final nonisolated class HostPasteStaging: @unchecked Sendable {
    static let shared = HostPasteStaging()

    static let guestDirectory = "/run/host/paste"
    static var hostDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermPaste", directoryHint: .isDirectory)
    }

    private static let staleFileAge: TimeInterval = 24 * 60 * 60
    private static let linuxNativeImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
    ]

    struct ProviderItem: @unchecked Sendable {
        let provider: NSItemProvider
        let type: UTType
    }

    private let lock = NSLock()
    private weak var runtime: LinuxRuntime?
    private var usesVirtioFS = true
    private var reservedNames: Set<String> = []

    private init() {}

    func attach(to runtime: LinuxRuntime, usesVirtioFS: Bool) {
        lock.withLock {
            self.runtime = runtime
            self.usesVirtioFS = usesVirtioFS
        }
    }

    func detach(from runtime: LinuxRuntime?) {
        lock.withLock {
            if self.runtime === runtime || runtime == nil {
                self.runtime = nil
            }
        }
    }

    static func prepareHostDirectory() -> Bool {
        let directory = hostDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            return false
        }
        sweepStaleFiles(in: directory)
        return true
    }

    static func removeAllFiles() {
        try? FileManager.default.removeItem(at: hostDirectory)
    }

    static func hasPasteboardContent(_ pasteboard: UIPasteboard = .general) -> Bool {
        if pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages {
            return true
        }
        if pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            return true
        }
        return stageableType(among: pasteboard.types) != nil
    }

    static func stageableType(among identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            return image
        }
        if types.contains(where: { $0.conforms(to: .text) }) {
            return nil
        }
        return types.first { type in
            !type.isDynamic
                && type.conforms(to: .data)
                && !type.conforms(to: .text)
                && !type.conforms(to: .url)
        }
    }

    static func plainText(string: String?, urls: [URL]) -> String? {
        let nonFileURLs = urls.filter { url in
            !url.isFileURL && (string.map { !urlSpellsString($0, url) } ?? true)
        }
        if !nonFileURLs.isEmpty {
            return nonFileURLs.map(\.absoluteString).joined(separator: " ")
        }
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    static func fileURLs(in pasteboard: UIPasteboard) -> [URL] {
        var result: [URL] = []
        if pasteboard.hasURLs, let urls = pasteboard.urls {
            result.append(contentsOf: urls.filter(\.isFileURL))
        }
        if result.isEmpty, pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            for item in pasteboard.items {
                guard let raw = item[UTType.fileURL.identifier] else { continue }
                if let url = raw as? URL, url.isFileURL {
                    result.append(url)
                } else if let data = raw as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    result.append(url)
                } else if let str = raw as? String, let url = URL(string: str), url.isFileURL {
                    result.append(url)
                }
            }
        }
        return result
    }

    static func normalizedPNGData(for image: UIImage) -> Data? {
        if image.imageOrientation == .up, let data = image.pngData() {
            return data
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.pngData()
    }

    @MainActor
    func stageFileURLs(_ urls: [URL], completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard Self.prepareHostDirectory() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var staged: [String] = []
            for url in urls where url.isFileURL {
                if let guestPath = stageSingleSourceFile(at: url, suggestedName: url.lastPathComponent, type: nil) {
                    staged.append(guestPath)
                }
            }
            publishAndComplete(staged, completion: completion)
        }
    }

    @MainActor
    func stageProviders(_ items: [ProviderItem], completion: @escaping @MainActor (String?) -> Void) {
        guard Self.prepareHostDirectory() else {
            completion(nil)
            return
        }
        final class OrderedPaths: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String?]
            init(count: Int) {
                values = Array(repeating: nil, count: count)
            }

            func set(_ value: String?, at index: Int) {
                lock.withLock { values[index] = value }
            }

            var compacted: [String] {
                lock.withLock { values.compactMap(\.self) }
            }
        }
        let ordered = OrderedPaths(count: items.count)
        let group = DispatchGroup()
        for (index, item) in items.enumerated() {
            group.enter()
            let suggested = item.provider.suggestedName
            let itemType = item.type
            item.provider.loadFileRepresentation(forTypeIdentifier: itemType.identifier) { [self] url, _ in
                defer { group.leave() }
                guard let url else { return }
                let path = stageSingleSourceFile(at: url, suggestedName: suggested, type: itemType)
                ordered.set(path, at: index)
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { @Sendable [self] in
            publishAndComplete(ordered.compacted, completion: completion)
        }
    }

    @MainActor
    func stagePasteboardFallbackImage(_ pasteboard: UIPasteboard, completion: @escaping @MainActor (String?) -> Void) {
        let pngData = pasteboard.data(forPasteboardType: UTType.png.identifier)
        let jpegData = pngData == nil ? pasteboard.data(forPasteboardType: UTType.jpeg.identifier) : nil
        let decodedPNG = (pngData == nil && jpegData == nil) ? pasteboard.image.flatMap(Self.normalizedPNGData) : nil

        guard let payload: (data: Data, ext: String) = if let pngData {
            (pngData, "png")
        } else if let jpegData {
            (jpegData, "jpg")
        } else if let decodedPNG {
            (decodedPNG, "png")
        } else {
            nil
        } else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard Self.prepareHostDirectory() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var staged: [String] = []
            if let guestPath = storeFile(name: "image", extension: payload.ext, write: { try payload.data.write(to: $0, options: .atomic) }) {
                staged.append(guestPath)
            }
            publishAndComplete(staged, completion: completion)
        }
    }

    private func stageSingleSourceFile(at sourceURL: URL, suggestedName: String?, type: UTType?) -> String? {
        var resolvedType = type
        if resolvedType == nil, !sourceURL.pathExtension.isEmpty {
            resolvedType = UTType(filenameExtension: sourceURL.pathExtension)
        }
        let (baseName, rawExtension) = Self.splitFileName(suggested: suggestedName ?? sourceURL.lastPathComponent, type: resolvedType)
        let lowerExt = rawExtension.lowercased()
        let isImage = (resolvedType?.conforms(to: .image) ?? false)
            || UTType(filenameExtension: lowerExt)?.conforms(to: .image) == true

        return try? sourceURL.withSecurityScopedAccess {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return nil
            }
            if isImage, !Self.linuxNativeImageExtensions.contains(lowerExt),
               let data = try? Data(contentsOf: sourceURL),
               let image = UIImage(data: data),
               let png = Self.normalizedPNGData(for: image)
            {
                return storeFile(name: baseName, extension: "png") { destination in
                    try png.write(to: destination, options: .atomic)
                }
            }
            return storeFile(name: baseName, extension: rawExtension) { destination in
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
        }
    }

    private func storeFile(name: String, extension fileExtension: String, write: (URL) throws -> Void) -> String? {
        let cleanName = name.isEmpty ? "file" : Self.shellSafeName(name)
        let cleanExt = fileExtension.isEmpty ? "bin" : Self.shellSafeName(fileExtension)
        let directory = Self.hostDirectory
        let fileName: String = lock.withLock {
            let stamp = Int(Date().timeIntervalSince1970)
            var candidate = "\(cleanName)-\(stamp).\(cleanExt)"
            var counter = 1
            while reservedNames.contains(candidate)
                || FileManager.default.fileExists(atPath: directory.appending(path: candidate).path(percentEncoded: false))
            {
                candidate = "\(cleanName)-\(stamp)-\(counter).\(cleanExt)"
                counter += 1
            }
            reservedNames.insert(candidate)
            return candidate
        }
        defer {
            lock.withLock { _ = reservedNames.remove(fileName) }
        }
        let destination = directory.appending(path: fileName)
        do {
            try write(destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644, .modificationDate: Date()],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
            return Self.guestDirectory + "/" + fileName
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private func publishAndComplete(_ guestPaths: [String], completion: @escaping @MainActor (String?) -> Void) {
        guard !guestPaths.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let (targetRuntime, virtioFS) = lock.withLock { (runtime, usesVirtioFS) }
        if !virtioFS, let targetRuntime {
            let hostDir = Self.hostDirectory
            Task.detached(priority: .userInitiated) {
                var synced: [String] = []
                for guestPath in guestPaths {
                    let fileName = (guestPath as NSString).lastPathComponent
                    let hostFile = hostDir.appending(path: fileName)
                    if let data = try? Data(contentsOf: hostFile),
                       (try? await targetRuntime.fileSystem.writeFile(guestPath, contents: data, permissions: 0o644)) != nil
                    {
                        synced.append(guestPath)
                    }
                }
                let joined = synced.isEmpty ? nil : synced.joined(separator: " ")
                await MainActor.run {
                    completion(joined)
                }
            }
            return
        }
        let joined = guestPaths.joined(separator: " ")
        DispatchQueue.main.async {
            completion(joined)
        }
    }

    private static func splitFileName(suggested: String?, type: UTType?) -> (name: String, extension: String) {
        let preferred = type?.preferredFilenameExtension ?? "bin"
        guard let suggested = suggested as NSString?, suggested.length > 0 else {
            return ((type?.conforms(to: .image) ?? false) ? "image" : "file", preferred)
        }
        let ext = suggested.pathExtension
        return (
            ext.isEmpty ? (suggested as String) : suggested.deletingPathExtension,
            ext.isEmpty ? preferred : ext
        )
    }

    private static func shellSafeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func urlSpellsString(_ string: String, _ url: URL) -> Bool {
        let lhs = (url.absoluteString.removingPercentEncoding ?? url.absoluteString).trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = (string.removingPercentEncoding ?? string).trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs == rhs
    }

    private static func sweepStaleFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-staleFileAge)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
