import Foundation
import Observation

nonisolated enum LinuxDistribution: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case alma
    case alpine
    case arch
    case centos
    case debian
    case devuan
    case fedora
    case gentoo
    case kali
    case nixos
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
        case .gentoo: "Gentoo"
        case .kali: "Kali"
        case .nixos: "NixOS"
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
        case .gentoo: "gentoo"
        case .kali: "kali"
        case .nixos: "nixos"
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
        case .gentoo, .nixos, .void: nil
        }
    }

    static func fromSimplestreamsOS(_ os: String) -> LinuxDistribution? {
        let normalized = os.lowercased()
        return allCases.first { $0.simplestreamsOSKey == normalized }
    }

    var repository: MirrorRepository {
        switch self {
        case .alma, .alpine, .arch, .centos, .debian, .devuan, .fedora, .kali, .openEuler, .openSUSE, .oracle, .rocky, .ubuntu:
            .lxc
        case .gentoo: .gentoo
        case .nixos: .nixos
        case .void: .void
        }
    }

    var requiresSystemInit: Bool {
        self == .nixos
    }

    func systemInit(variant: String?) -> SystemInit? {
        switch self {
        case .alma, .arch, .centos, .debian, .fedora, .kali, .openEuler, .openSUSE, .oracle, .rocky, .ubuntu:
            .systemd
        case .alpine, .devuan, .nixos, .void:
            .other
        case .gentoo:
            switch variant {
            case "systemd": .systemd
            case "openrc": .other
            default: nil
            }
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
    let variant: String
    let displayTitle: String
    let buildSerial: String
    let artifactPath: String
    let compressedBytes: Int64?
    let sha256: String
    let sortRank: Int
    let isRecommended: Bool
}

nonisolated struct ContainerSetup: Codable, Equatable, Sendable {
    var mirrorID: String?
    var password: String?
    var software: ContainerSoftware?
}

nonisolated struct ContainerMetadata: Codable, Equatable, Sendable {
    var schemaVersion = 2
    let name: String
    var distributionID: String?
    let distributionVariant: String?
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

    func releases(for distribution: LinuxDistribution) -> [LinuxReleaseImage] {
        releasesByDistribution[distribution] ?? []
    }

    func defaultRelease(for distribution: LinuxDistribution) -> LinuxReleaseImage? {
        let releases = releases(for: distribution)
        return releases.first(where: \.isRecommended) ?? releases.first
    }

    func loadIfNeeded(mirror: DistributionMirror?) async {
        if case .loaded = loadState, !releasesByDistribution.isEmpty {
            return
        }
        if let activeTask {
            await activeTask.value
            return
        }
        await refresh(mirror: mirror)
    }

    func refresh(mirror: DistributionMirror?) async {
        activeTask?.cancel()
        loadState = .loading
        let task = Task<Void, Never> {
            do {
                let releases = try await LinuxDistributionCatalogClient.fetchARM64Catalog(mirror: mirror)
                guard !Task.isCancelled else { return }
                releasesByDistribution = releases
                loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                if releasesByDistribution.isEmpty {
                    loadState = .failed(error.localizedDescription)
                } else {
                    loadState = .loaded
                }
            }
            activeTask = nil
        }
        activeTask = task
        await task.value
    }
}

private nonisolated enum LinuxDistributionCatalogClient {
    private static let gentooAutobuildsPath = "releases/arm64/autobuilds"
    private static let voidChecksumsPath = "live/current/sha256sum.txt"
    private static let nixOSChannels: [(release: String, jobset: String, title: String, rank: Int, isRecommended: Bool)] = [
        ("unstable", "trunk-combined", "Unstable", 1_000_000, true),
        ("26.05", "release-26.05", "26.05", numericRank("26.05"), false),
    ]

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
        let size: Int64?
        let sha256: String?
    }

    private struct HydraBuild: Decodable {
        let id: Int
        let finished: Int
        let buildstatus: Int?
        let buildproducts: [String: HydraBuildProduct]
    }

    private struct HydraBuildProduct: Decodable {
        let type: String
        let subtype: String?
        let name: String
        let filesize: Int64?
        let sha256hash: String?
    }

    static func fetchARM64Catalog(mirror: DistributionMirror?) async throws -> [LinuxDistribution: [LinuxReleaseImage]] {
        async let simplestreams = Result { try await fetchSimplestreams(mirror: mirror) }
        async let gentoo = Result { try await fetchGentoo(mirror: mirror) }
        async let void = Result { try await fetchVoid(mirror: mirror) }
        async let nixOS = Result { try await fetchNixOS() }

        var grouped: [LinuxDistribution: [LinuxReleaseImage]] = [:]
        var firstError: Error?
        for result in await [simplestreams, gentoo, void, nixOS] {
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

    private static func fetch(_ url: URL, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func fetchText(_ url: URL) async throws -> String {
        guard let text = try String(data: await fetch(url), encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    private static func fetchSimplestreams(mirror: DistributionMirror?) async throws -> [LinuxReleaseImage] {
        let candidates = DistributionMirrorRouter.candidates(for: .lxc, preferring: mirror) { endpoint in
            endpoint.lxcIndexPath.map(endpoint.url(for:))
        }
        let document = try await DistributionMirrorRouter.firstSuccess(of: candidates) { candidate in
            try JSONDecoder().decode(SimplestreamsDocument.self, from: await fetch(candidate.url))
        }
        var images: [LinuxReleaseImage] = []
        for (productKey, product) in document.products {
            guard product.arch == "arm64",
                  product.variant == "default",
                  let os = product.os,
                  let distribution = LinuxDistribution.fromSimplestreamsOS(os),
                  let release = product.release,
                  let versions = product.versions,
                  let latestSerial = versions.keys.sorted().last,
                  let tarItem = versions[latestSerial]?.items?["root.tar.xz"],
                  let artifactPath = tarItem.path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  !artifactPath.isEmpty,
                  let sha256 = validSHA256(tarItem.sha256)
            else {
                continue
            }
            let label = formatReleaseLabel(distribution: distribution, release: release, releaseTitle: product.releaseTitle)
            images.append(LinuxReleaseImage(
                id: productKey,
                distribution: distribution,
                releaseKey: release,
                variant: "default",
                displayTitle: label.title,
                buildSerial: latestSerial,
                artifactPath: artifactPath,
                compressedBytes: tarItem.size,
                sha256: sha256,
                sortRank: label.rank,
                isRecommended: distribution == .ubuntu && release.lowercased() == "noble"
            ))
        }
        return images
    }

    private static func fetchGentoo(mirror: DistributionMirror?) async throws -> [LinuxReleaseImage] {
        let candidates = DistributionMirrorRouter.candidates(for: .gentoo, preferring: mirror) { endpoint in
            endpoint.url(for: "\(gentooAutobuildsPath)/latest-stage3-arm64-systemd.txt")
        }
        return try await DistributionMirrorRouter.firstSuccess(of: candidates) { candidate in
            try await fetchGentoo(from: candidate.endpoint)
        }
    }

    private static func fetchGentoo(from endpoint: MirrorEndpoint) async throws -> [LinuxReleaseImage] {
        try await withThrowingTaskGroup(of: LinuxReleaseImage.self) { group in
            for (variant, title, rank) in [("systemd", "Rolling (systemd)", 200), ("openrc", "Rolling (OpenRC)", 100)] {
                group.addTask {
                    let pointer = try await fetchText(endpoint.url(for: "\(gentooAutobuildsPath)/latest-stage3-arm64-\(variant).txt"))
                    guard let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasSuffix(".tar.xz") || $0.contains(".tar.xz ") }),
                          case let fields = line.split(separator: " "),
                          let relativePath = fields.first.map(String.init),
                          relativePath.hasSuffix(".tar.xz"),
                          let serial = relativePath.split(separator: "/").first.map(String.init)
                    else {
                        throw URLError(.cannotParseResponse)
                    }
                    let artifactPath = "\(gentooAutobuildsPath)/\(relativePath)"
                    let checksums = try await fetchText(endpoint.url(for: "\(artifactPath).sha256"))
                    guard let file = relativePath.split(separator: "/").last.map(String.init),
                          let sha256 = checksum(for: file, in: checksums)
                    else {
                        throw URLError(.cannotParseResponse)
                    }
                    return LinuxReleaseImage(
                        id: "gentoo:stage3:arm64:\(variant)",
                        distribution: .gentoo,
                        releaseKey: "current",
                        variant: variant,
                        displayTitle: title,
                        buildSerial: serial,
                        artifactPath: artifactPath,
                        compressedBytes: fields.count > 1 ? Int64(fields[1]) : nil,
                        sha256: sha256,
                        sortRank: rank,
                        isRecommended: variant == "systemd"
                    )
                }
            }
            var images: [LinuxReleaseImage] = []
            for try await image in group {
                images.append(image)
            }
            return images
        }
    }

    private static func fetchVoid(mirror: DistributionMirror?) async throws -> [LinuxReleaseImage] {
        let candidates = DistributionMirrorRouter.candidates(for: .void, preferring: mirror) { endpoint in
            endpoint.url(for: voidChecksumsPath)
        }
        let checksums = try await DistributionMirrorRouter.firstSuccess(of: candidates) { candidate in
            try await fetchText(candidate.url)
        }
        let prefix = "void-aarch64-ROOTFS-"
        for line in checksums.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let file = String(line[line.index(after: open) ..< close])
            guard file.hasPrefix(prefix), file.hasSuffix(".tar.xz"),
                  let sha256 = validSHA256(line.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) })
            else {
                continue
            }
            let serial = String(file.dropFirst(prefix.count).dropLast(".tar.xz".count))
            guard !serial.isEmpty, serial.allSatisfy(\.isNumber) else { continue }
            return [LinuxReleaseImage(
                id: "void:rootfs:arm64:glibc",
                distribution: .void,
                releaseKey: "current",
                variant: "default",
                displayTitle: "Rolling",
                buildSerial: serial,
                artifactPath: "live/\(serial)/\(file)",
                compressedBytes: nil,
                sha256: sha256,
                sortRank: 1000,
                isRecommended: true
            )]
        }
        throw URLError(.cannotParseResponse)
    }

    private static func fetchNixOS() async throws -> [LinuxReleaseImage] {
        try await withThrowingTaskGroup(of: LinuxReleaseImage?.self) { group in
            for channel in nixOSChannels {
                group.addTask {
                    try? await fetchNixOS(
                        release: channel.release,
                        jobset: channel.jobset,
                        title: channel.title,
                        rank: channel.rank,
                        isRecommended: channel.isRecommended
                    )
                }
            }
            var images: [LinuxReleaseImage] = []
            for try await image in group {
                if let image {
                    images.append(image)
                }
            }
            guard !images.isEmpty else {
                throw URLError(.cannotParseResponse)
            }
            return images
        }
    }

    private static func fetchNixOS(
        release: String,
        jobset: String,
        title: String,
        rank: Int,
        isRecommended: Bool
    ) async throws -> LinuxReleaseImage {
        let candidates = DistributionMirrorRouter.candidates(for: .nixos, preferring: nil) { endpoint in
            endpoint.url(for: "job/nixos/\(jobset)/nixos.containerTarball.aarch64-linux/latest")
        }
        let build = try await DistributionMirrorRouter.firstSuccess(of: candidates) { candidate in
            try JSONDecoder().decode(HydraBuild.self, from: await fetch(candidate.url, accept: "application/json"))
        }
        guard build.finished == 1, build.buildstatus == 0,
              let (productKey, product) = build.buildproducts
                  .sorted(by: { $0.key < $1.key })
                  .first(where: { $0.value.type == "file" && $0.value.name.hasSuffix(".tar.xz") }),
              let sha256 = validSHA256(product.sha256hash)
        else {
            throw URLError(.cannotParseResponse)
        }
        return LinuxReleaseImage(
            id: "nixos:\(release):arm64:hydra",
            distribution: .nixos,
            releaseKey: release,
            variant: "default",
            displayTitle: title,
            buildSerial: String(build.id),
            artifactPath: "build/\(build.id)/download/\(productKey)/\(product.name)",
            compressedBytes: product.filesize,
            sha256: sha256,
            sortRank: rank,
            isRecommended: isRecommended
        )
    }

    private static func checksum(for file: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[1] == file, let sha256 = validSHA256(String(fields[0])) {
                return sha256
            }
        }
        return nil
    }

    private static func validSHA256(_ value: String?) -> String? {
        guard let value = value?.lowercased(), value.count == 64, value.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return value
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
        case .alma, .fedora, .gentoo, .nixos, .oracle, .rocky, .void:
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
