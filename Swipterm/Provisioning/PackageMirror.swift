import Foundation

nonisolated enum PackageSource: Sendable {
    case upstream
    case mirror(name: String, root: PackageRepositoryRoot)
}

nonisolated enum PackageMirrorResolver {
    static func resolve(
        for distribution: LinuxDistribution,
        release: OSRelease,
        mirrorID: String?
    ) async -> PackageSource {
        if let selected = DistributionMirror.all.first(where: { $0.id == mirrorID }) {
            if selected.id == DistributionMirror.official.id {
                return official(for: distribution, release: release)
            }
            if let root = selected.packageRoot(for: distribution, release: release) {
                return .mirror(name: selected.name, root: completed(root, for: distribution))
            }
            if selected.region == .cn,
               let source = await fastestMirror(in: .cn, for: distribution, release: release)
            {
                return source
            }
            return official(for: distribution, release: release)
        }
        guard await DistributionMirrorRouter.regionDetector.region() == .cn else {
            return .upstream
        }
        return await fastestMirror(in: .cn, for: distribution, release: release) ?? .upstream
    }

    private static func official(for distribution: LinuxDistribution, release: OSRelease) -> PackageSource {
        switch distribution {
        case .alma, .centos, .fedora, .rocky:
            return .upstream
        default:
            let mirror = DistributionMirror.official
            guard let root = mirror.packageRoot(for: distribution, release: release) else {
                return .upstream
            }
            return .mirror(name: mirror.name, root: root)
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

    private static func fastestMirror(
        in region: MirrorRegion,
        for distribution: LinuxDistribution,
        release: OSRelease
    ) async -> PackageSource? {
        let candidates = DistributionMirror.all.compactMap { mirror -> (name: String, root: PackageRepositoryRoot)? in
            guard mirror.region == region, let root = mirror.packageRoot(for: distribution, release: release) else {
                return nil
            }
            return (mirror.name, completed(root, for: distribution))
        }
        guard let path = probePath(for: distribution, release: release) else {
            return candidates.first.map { .mirror(name: $0.name, root: $0.root) }
        }
        return await withTaskGroup(of: PackageSource?.self) { group in
            for candidate in candidates {
                guard let url = URL(string: "\(candidate.root.url)/\(path)") else { continue }
                group.addTask {
                    await MirrorProbe.responds(url) ? .mirror(name: candidate.name, root: candidate.root) : nil
                }
            }
            for await source in group {
                if let source {
                    group.cancelAll()
                    return source
                }
            }
            return nil
        }
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
