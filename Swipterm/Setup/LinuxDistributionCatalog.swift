import Foundation
import Observation
import SwiptermKit

nonisolated enum LinuxDistribution: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case alma
    case alpine
    case arch
    case centos
    case debian
    case devuan
    case fedora
    case kali
    case openEuler
    case openSUSE
    case oracle
    case rocky
    case ubuntu
    case void

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .alma: "Alma"
        case .alpine: "Alpine"
        case .arch: "Arch"
        case .centos: "CentOS"
        case .debian: "Debian"
        case .devuan: "Devuan"
        case .fedora: "Fedora"
        case .kali: "Kali"
        case .openEuler: "openEuler"
        case .openSUSE: "openSUSE"
        case .oracle: "Oracle"
        case .rocky: "Rocky"
        case .ubuntu: "Ubuntu"
        case .void: "Void"
        }
    }

    var defaultContainerName: String {
        switch self {
        case .alma: "alma"
        case .alpine: "alpine"
        case .arch: "arch"
        case .centos: "centos"
        case .debian: "debian"
        case .devuan: "devuan"
        case .fedora: "fedora"
        case .kali: "kali"
        case .openEuler: "openeuler"
        case .openSUSE: "opensuse"
        case .oracle: "oracle"
        case .rocky: "rocky"
        case .ubuntu: "ubuntu"
        case .void: "void"
        }
    }

    var simplestreamsOSKey: String? {
        switch self {
        case .alma: "almalinux"
        case .alpine: "alpine"
        case .arch: "archlinux"
        case .centos: "centos"
        case .debian: "debian"
        case .devuan: "devuan"
        case .fedora: "fedora"
        case .kali: "kali"
        case .openEuler: "openeuler"
        case .openSUSE: "opensuse"
        case .oracle: "oracle"
        case .rocky: "rockylinux"
        case .ubuntu: "ubuntu"
        case .void: nil
        }
    }

    static func fromSimplestreamsOS(_ os: String) -> LinuxDistribution? {
        let normalized = os.lowercased()
        return allCases.first { $0.simplestreamsOSKey == normalized }
    }

    fileprivate var imageServerURL: URL {
        switch self {
        case .alma, .alpine, .arch, .centos, .debian, .devuan, .fedora, .kali, .openEuler, .openSUSE, .oracle, .rocky, .ubuntu:
            LinuxDistributionCatalogClient.simplestreamsServerURL
        case .void:
            LinuxDistributionCatalogClient.voidServerURL
        }
    }

    var systemInit: SystemInit {
        switch self {
        case .alma, .arch, .centos, .debian, .fedora, .kali, .openEuler, .openSUSE, .oracle, .rocky, .ubuntu:
            .systemd
        case .alpine, .devuan, .void:
            .other
        }
    }

    fileprivate var unsupportedReleases: Set<String> {
        switch self {
        case .alma, .oracle, .rocky: ["8"]
        default: []
        }
    }
}

nonisolated enum SystemInit: String, Codable, Sendable {
    case systemd
    case other
    case absent

    var requiredInitMode: ContainerInitMode? {
        switch self {
        case .systemd: nil
        case .other: .system
        case .absent: .managed
        }
    }
}

nonisolated enum ContainerInitMode: String, Codable, Hashable, Sendable {
    case managed
    case system
}

nonisolated struct LinuxReleaseImage: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let distribution: LinuxDistribution
    let releaseKey: String
    let displayTitle: String
    let buildSerial: String
    let artifactPath: String
    let sortRank: Int
    let isRecommended: Bool

    var archiveURL: URL {
        distribution.imageServerURL.appending(path: artifactPath, directoryHint: .notDirectory)
    }
}

nonisolated struct ContainerSetup: Codable, Equatable, Sendable {
    var password: String?
    var software: ContainerSoftware?
}

nonisolated struct ContainerMetadata: Codable, Equatable, Sendable {
    var schemaVersion = 2
    let name: String
    var distributionID: String?
    var systemInit: SystemInit?
    let installedAt: Date
    var initMode: ContainerInitMode
    var defaultUser: String
    var setupCompleted: Bool
    var setup: ContainerSetup?
    var sshPort: Int?

    var distribution: LinuxDistribution? {
        distributionID.flatMap(LinuxDistribution.init(rawValue:))
    }
}

@Observable
final class LinuxDistributionCatalogStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let shared = LinuxDistributionCatalogStore()

    private(set) var loadState: LoadState = .idle
    private(set) var releasesByDistribution: [LinuxDistribution: [LinuxReleaseImage]] = [:]

    private var activeTask: Task<Void, Never>?

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        private init() {
            if StoreScreenshot.current == .setup {
                releasesByDistribution = [.alpine: [StoreScreenshot.alpineRelease]]
                loadState = .loaded
            }
        }
    #endif

    func releases(for distribution: LinuxDistribution) -> [LinuxReleaseImage] {
        releasesByDistribution[distribution] ?? []
    }

    func defaultRelease(for distribution: LinuxDistribution) -> LinuxReleaseImage? {
        let releases = releases(for: distribution)
        return releases.first(where: \.isRecommended) ?? releases.first
    }

    func loadIfNeeded() async {
        if case .loaded = loadState, !releasesByDistribution.isEmpty {
            return
        }
        if let activeTask {
            await activeTask.value
            return
        }
        await refresh()
    }

    func refresh() async {
        activeTask?.cancel()
        loadState = .loading
        let task = Task<Void, Never> {
            do {
                let releases = try await LinuxDistributionCatalogClient.fetchARM64Catalog()
                guard !Task.isCancelled else { return }
                releasesByDistribution = releases
                loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                releasesByDistribution = [:]
                loadState = .failed(error.localizedDescription)
            }
            activeTask = nil
        }
        activeTask = task
        await task.value
    }
}

private nonisolated enum LinuxDistributionCatalogClient {
    static let simplestreamsServerURL = URL(string: "https://images.linuxcontainers.org")!
    static let voidServerURL = URL(string: "https://repo-fastly.voidlinux.org")!

    private struct SimplestreamsDocument: Decodable {
        let products: [String: SimplestreamsProduct]
    }

    private struct SimplestreamsProduct: Decodable {
        let arch: String?
        let os: String?
        let release: String?
        let releaseTitle: String?
        let variant: String?
        let versions: [String: SimplestreamsVersion]?

        enum CodingKeys: String, CodingKey {
            case arch
            case os
            case release
            case releaseTitle = "release_title"
            case variant
            case versions
        }
    }

    private struct SimplestreamsVersion: Decodable {
        let items: [String: SimplestreamsItem]?
    }

    private struct SimplestreamsItem: Decodable {
        let path: String?
    }

    static func fetchARM64Catalog() async throws -> [LinuxDistribution: [LinuxReleaseImage]] {
        async let simplestreams = Result { try await fetchSimplestreams() }
        async let void = Result { try await fetchVoid() }

        var grouped: [LinuxDistribution: [LinuxReleaseImage]] = [:]
        var firstError: Error?
        for result in await [simplestreams, void] {
            switch result {
            case let .success(images):
                for image in images {
                    grouped[image.distribution, default: []].append(image)
                }
            case let .failure(error):
                firstError = firstError ?? error
            }
        }
        if grouped.isEmpty, let firstError {
            throw firstError
        }

        for distribution in grouped.keys {
            grouped[distribution]?.sort { lhs, rhs in
                if lhs.sortRank != rhs.sortRank {
                    return lhs.sortRank > rhs.sortRank
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedDescending
            }
        }
        return grouped
    }

    private static func fetch(_ path: String, from server: URL) async throws -> Data {
        let (data, response) = try await HTTPClient.data(from: server.appending(path: path, directoryHint: .notDirectory))
        try response.requireSuccess()
        return data
    }

    private static func fetchSimplestreams() async throws -> [LinuxReleaseImage] {
        let document = try await JSONDecoder().decode(
            SimplestreamsDocument.self,
            from: fetch("streams/v1/images.json", from: simplestreamsServerURL)
        )
        var images: [LinuxReleaseImage] = []
        for (productKey, product) in document.products {
            guard product.arch == "arm64",
                  product.variant == "default",
                  let os = product.os,
                  let distribution = LinuxDistribution.fromSimplestreamsOS(os),
                  let release = product.release,
                  !distribution.unsupportedReleases.contains(release),
                  let versions = product.versions,
                  let latestSerial = versions.keys.sorted().last,
                  let tarItem = versions[latestSerial]?.items?["root.tar.xz"],
                  let artifactPath = tarItem.path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  !artifactPath.isEmpty
            else {
                continue
            }
            let label = formatReleaseLabel(distribution: distribution, release: release, releaseTitle: product.releaseTitle)
            images.append(LinuxReleaseImage(
                id: productKey,
                distribution: distribution,
                releaseKey: release,
                displayTitle: label.title,
                buildSerial: latestSerial,
                artifactPath: artifactPath,
                sortRank: label.rank,
                isRecommended: distribution == .ubuntu && release.lowercased() == "noble"
            ))
        }
        return images
    }

    private static func fetchVoid() async throws -> [LinuxReleaseImage] {
        guard let checksums = try await String(data: fetch("live/current/sha256sum.txt", from: voidServerURL), encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let prefix = "void-aarch64-ROOTFS-"
        for line in checksums.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let file = String(line[line.index(after: open) ..< close])
            guard file.hasPrefix(prefix), file.hasSuffix(".tar.xz") else { continue }
            let serial = String(file.dropFirst(prefix.count).dropLast(".tar.xz".count))
            guard !serial.isEmpty, serial.allSatisfy(\.isNumber) else { continue }
            return [LinuxReleaseImage(
                id: "void:rootfs:arm64:glibc",
                distribution: .void,
                releaseKey: "current",
                displayTitle: "Rolling",
                buildSerial: serial,
                artifactPath: "live/\(serial)/\(file)",
                sortRank: 1000,
                isRecommended: true
            )]
        }
        throw URLError(.cannotParseResponse)
    }

    private static func formatReleaseLabel(
        distribution: LinuxDistribution,
        release: String,
        releaseTitle: String?
    ) -> (title: String, rank: Int) {
        let lowered = release.lowercased()
        switch distribution {
        case .ubuntu:
            switch lowered {
            case "resolute": return ("26.04 LTS (Resolute)", 26040)
            case "stonking": return ("26.10 (Stonking)", 26030)
            case "noble": return ("24.04 LTS (Noble)", 24040)
            case "jammy": return ("22.04 LTS (Jammy)", 22040)
            case "focal": return ("20.04 LTS (Focal)", 20040)
            default: return (releaseTitle ?? release.capitalized, numericRank(release))
            }
        case .debian:
            switch lowered {
            case "trixie": return ("13 (Trixie)", 1300)
            case "bookworm": return ("12 (Bookworm)", 1200)
            case "bullseye": return ("11 (Bullseye)", 1100)
            case "forky": return ("Forky (Testing)", 1250)
            case "sid": return ("Sid (Unstable)", 1240)
            default: return (releaseTitle ?? release.capitalized, numericRank(release))
            }
        case .devuan:
            switch lowered {
            case "excalibur": return ("6 (Excalibur)", 600)
            case "daedalus": return ("5 (Daedalus)", 500)
            case "chimaera": return ("4 (Chimaera)", 400)
            default: return (releaseTitle ?? release.capitalized, numericRank(release))
            }
        case .alpine:
            if lowered == "edge" {
                return ("Edge", 100)
            }
            return (releaseTitle ?? release, numericRank(release) + 1000)
        case .centos:
            if lowered.hasSuffix("-stream") {
                let major = release.replacingOccurrences(of: "-Stream", with: "", options: .caseInsensitive)
                return ("Stream \(major)", numericRank(major) + 1000)
            }
            return (releaseTitle ?? release, numericRank(release))
        case .openSUSE:
            if lowered == "tumbleweed" {
                return ("Tumbleweed", 2000)
            }
            return ("Leap \(releaseTitle ?? release)", numericRank(release) + 1000)
        case .arch, .kali:
            if lowered == "current" {
                return ("Rolling", 1000)
            }
            return (releaseTitle ?? release, numericRank(release))
        case .openEuler:
            if lowered == "24.03" {
                return ("24.03 LTS", 24030)
            }
            return (releaseTitle ?? release, numericRank(release))
        case .alma, .fedora, .oracle, .rocky, .void:
            return (releaseTitle ?? release, numericRank(release))
        }
    }

    private static func numericRank(_ text: String) -> Int {
        let parts = text
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        guard let major = parts.first else { return 0 }
        let minor = parts.count > 1 ? parts[1] : 0
        return major * 100 + minor
    }
}
