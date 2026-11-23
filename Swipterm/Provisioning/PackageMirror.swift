import Foundation

nonisolated struct PackageMirror: Sendable {
    let name: String
    let root: PackageRepositoryRoot
}

nonisolated enum PackageMirrorError: LocalizedError {
    case unreachable(MirrorRegion)

    var errorDescription: String? {
        switch self {
        case let .unreachable(region):
            let region = String(localized: region.displayName)
            return String(localized: "No package mirror in \(region) responded.")
        }
    }
}

nonisolated enum PackageMirrorResolver {
    private struct Responder: Sendable {
        let mirror: PackageMirror
        let probe: MirrorProbe.Response
    }

    private static let settlingWindow = Duration.milliseconds(400)
    private static let freshnessTolerance: TimeInterval = 6 * 60 * 60

    static func resolve(
        for distribution: LinuxDistribution,
        release: OSRelease,
        mirrorID: String?
    ) async throws -> PackageMirror? {
        if let selected = DistributionMirror.all.first(where: { $0.id == mirrorID }) {
            if selected.id == DistributionMirror.official.id {
                return official(for: distribution, release: release)
            }
            if let root = selected.packageRoot(for: distribution, release: release) {
                return PackageMirror(name: selected.name, root: completed(root, for: distribution))
            }
        }
        let region = await DistributionMirrorRouter.regionDetector.region()
        let candidates = DistributionMirror.all.compactMap { mirror -> PackageMirror? in
            guard region != .global, mirror.region == region, let root = mirror.packageRoot(for: distribution, release: release) else {
                return nil
            }
            return PackageMirror(name: mirror.name, root: completed(root, for: distribution))
        }
        guard !candidates.isEmpty else {
            return official(for: distribution, release: release)
        }
        guard let path = probePath(for: distribution, release: release) else {
            return candidates[0]
        }
        guard let mirror = await fastest(of: candidates, probing: path, freshness: distribution != .nixos) else {
            throw PackageMirrorError.unreachable(region)
        }
        return mirror
    }

    private static func official(for distribution: LinuxDistribution, release: OSRelease) -> PackageMirror? {
        switch distribution {
        case .alma, .centos, .fedora, .rocky:
            return nil
        default:
            let mirror = DistributionMirror.official
            return mirror.packageRoot(for: distribution, release: release).map { PackageMirror(name: mirror.name, root: $0) }
        }
    }

    private static func completed(_ root: PackageRepositoryRoot, for distribution: LinuxDistribution) -> PackageRepositoryRoot {
        guard distribution == .debian, root.securityURL == nil else {
            return root
        }
        var root = root
        root.securityURL = DistributionMirror.official.packages[.debian]?.securityURL
        return root
    }

    private static func fastest(of candidates: [PackageMirror], probing path: String, freshness: Bool) async -> PackageMirror? {
        var responders = await withTaskGroup(of: Responder?.self) { group in
            for candidate in candidates {
                guard let url = URL(string: "\(candidate.root.url)/\(path)") else { continue }
                group.addTask {
                    await MirrorProbe.probe(url).map { Responder(mirror: candidate, probe: $0) }
                }
            }
            var responded: [Responder] = []
            var deadline: ContinuousClock.Instant?
            for await responder in group {
                if let responder {
                    responded.append(responder)
                    if deadline == nil {
                        let settled = ContinuousClock.now + settlingWindow
                        deadline = settled
                        group.addTask {
                            try? await Task.sleep(until: settled, clock: .continuous)
                            return nil
                        }
                    }
                }
                if let deadline, deadline <= .now {
                    break
                }
            }
            group.cancelAll()
            return responded
        }
        if freshness, let newest = responders.compactMap(\.probe.lastModified).max() {
            responders.removeAll { responder in
                guard let lastModified = responder.probe.lastModified else { return true }
                return newest.timeIntervalSince(lastModified) > freshnessTolerance
            }
        }
        return responders.min { $0.probe.latency < $1.probe.latency }?.mirror
    }

    private static func probePath(for distribution: LinuxDistribution, release: OSRelease) -> String? {
        let major = release.majorVersion ?? ""
        let codename = release.versionCodename ?? "stable"
        switch distribution {
        case .alma, .rocky:
            return "\(major)/BaseOS/aarch64/os/repodata/repomd.xml"
        case .alpine:
            return "edge/main/aarch64/APKINDEX.tar.gz"
        case .arch:
            return "aarch64/core/core.db"
        case .centos:
            return "\(major)-stream/BaseOS/aarch64/os/repodata/repomd.xml"
        case .debian, .devuan, .ubuntu:
            return "dists/\(codename)/Release"
        case .fedora:
            return "releases/\(release.versionID ?? "")/Everything/aarch64/os/repodata/repomd.xml"
        case .gentoo:
            return "releases/arm64/binpackages/23.0/arm64/Packages"
        case .kali:
            return "dists/kali-rolling/Release"
        case .nixos:
            return "nix-cache-info"
        case .openEuler:
            return "openEuler-\(release.versionID ?? "")-LTS/OS/aarch64/repodata/repomd.xml"
        case .openSUSE:
            if release.isTumbleweed {
                return "ports/aarch64/tumbleweed/repo/oss/repodata/repomd.xml"
            }
            return "distribution/leap/\(release.versionID ?? "")/repo/oss/aarch64/repodata/repomd.xml"
        case .void:
            return "current/aarch64/aarch64-repodata"
        case .oracle:
            return nil
        }
    }
}
