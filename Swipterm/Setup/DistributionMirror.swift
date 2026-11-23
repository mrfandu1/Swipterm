import Foundation

nonisolated enum MirrorRepository: String, Codable, Hashable, Sendable {
    case lxc
    case gentoo
    case void
    case nixos
}

nonisolated enum MirrorRegion: CaseIterable, Hashable, Sendable {
    case global
    case cn
    case apac
    case na
    case eu

    var displayName: LocalizedStringResource {
        switch self {
        case .global: "Global"
        case .cn: "China Mainland"
        case .apac: "Asia Pacific"
        case .na: "North America"
        case .eu: "Europe"
        }
    }

    fileprivate var probeURLs: [URL] {
        let urls: [String] = switch self {
        case .global:
            []
        case .cn:
            [
                "https://mirrors.aliyun.com/alpine/MIRRORS.txt",
                "https://mirrors.cloud.tencent.com/alpine/MIRRORS.txt",
                "https://mirrors.sjtug.sjtu.edu.cn/alpine/MIRRORS.txt",
            ]
        case .apac:
            ["https://mirror.freedif.org/gentoo/releases/arm64/autobuilds/latest-stage3-arm64-systemd.txt"]
        case .na:
            ["https://gentoo.osuosl.org/releases/arm64/autobuilds/latest-stage3-arm64-systemd.txt"]
        case .eu:
            ["https://ftp.fau.de/gentoo/releases/arm64/autobuilds/latest-stage3-arm64-systemd.txt"]
        }
        return urls.map { URL(string: $0)! }
    }
}

nonisolated struct MirrorEndpoint: Hashable, Sendable {
    let repository: MirrorRepository
    let baseURL: URL
    let lxcIndexPath: String?

    func url(for path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appending(path: String(component), directoryHint: .notDirectory)
        }
    }

    fileprivate static func lxc(_ base: String, index: String? = nil) -> MirrorEndpoint {
        MirrorEndpoint(repository: .lxc, baseURL: URL(string: base)!, lxcIndexPath: index)
    }

    fileprivate static func gentoo(_ base: String) -> MirrorEndpoint {
        MirrorEndpoint(repository: .gentoo, baseURL: URL(string: base)!, lxcIndexPath: nil)
    }

    fileprivate static func void(_ base: String) -> MirrorEndpoint {
        MirrorEndpoint(repository: .void, baseURL: URL(string: base)!, lxcIndexPath: nil)
    }

    fileprivate static func nixos(_ base: String) -> MirrorEndpoint {
        MirrorEndpoint(repository: .nixos, baseURL: URL(string: base)!, lxcIndexPath: nil)
    }
}

nonisolated struct PackageRepositoryRoot: Hashable, Sendable, ExpressibleByStringLiteral {
    let url: String
    var securityURL: String?
    var hostsTumbleweed = false
    var releases: Set<String>?

    init(_ url: String, security: String? = nil, tumbleweed: Bool = false, releases: Set<String>? = nil) {
        self.url = url
        securityURL = security
        hostsTumbleweed = tumbleweed
        self.releases = releases
    }

    init(stringLiteral value: String) {
        self.init(value)
    }
}

nonisolated struct DistributionMirror: Identifiable, Sendable {
    let id: String
    let name: String
    let region: MirrorRegion
    let endpoints: [MirrorEndpoint]
    let packages: [LinuxDistribution: PackageRepositoryRoot]

    init(
        id: String,
        name: String,
        region: MirrorRegion,
        endpoints: [MirrorEndpoint],
        packages: [LinuxDistribution: PackageRepositoryRoot] = [:]
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.endpoints = endpoints
        self.packages = packages
    }

    func endpoints(for repository: MirrorRepository) -> [MirrorEndpoint] {
        endpoints.filter { $0.repository == repository }
    }

    func hosts(_ repository: MirrorRepository) -> Bool {
        endpoints.contains { $0.repository == repository }
    }

    func serves(_ distribution: LinuxDistribution) -> Bool {
        hosts(distribution.repository) || packages[distribution] != nil
    }

    func packageRoot(for distribution: LinuxDistribution, release: OSRelease) -> PackageRepositoryRoot? {
        guard let root = packages[distribution] else { return nil }
        if distribution == .openSUSE, release.isTumbleweed, !root.hostsTumbleweed {
            return nil
        }
        if let releases = root.releases, !releases.contains(release.versionID ?? "") {
            return nil
        }
        return root
    }

    static let official = DistributionMirror(id: "official", name: "Official", region: .global, endpoints: [
        .lxc("https://images.linuxcontainers.org", index: "streams/v1/images.json"),
        .gentoo("https://distfiles.gentoo.org"),
        .void("https://repo-fastly.voidlinux.org"),
        .void("https://repo-default.voidlinux.org"),
        .nixos("https://hydra.nixos.org"),
    ], packages: [
        .alma: "https://repo.almalinux.org/almalinux",
        .alpine: "https://dl-cdn.alpinelinux.org/alpine",
        .arch: "https://ca.us.mirror.archlinuxarm.org",
        .centos: "https://mirror.stream.centos.org",
        .debian: .init("https://deb.debian.org/debian", security: "https://deb.debian.org/debian-security"),
        .devuan: "https://pkgmaster.devuan.org/merged",
        .fedora: "https://dl.fedoraproject.org/pub/fedora/linux",
        .gentoo: "https://distfiles.gentoo.org",
        .kali: "https://kali.download/kali",
        .nixos: "https://cache.nixos.org",
        .openEuler: "https://repo.openeuler.org",
        .openSUSE: .init("https://download.opensuse.org", tumbleweed: true),
        .oracle: "https://yum.oracle.com/repo/OracleLinux",
        .rocky: "https://dl.rockylinux.org/pub/rocky",
        .ubuntu: "https://ports.ubuntu.com/ubuntu-ports",
        .void: "https://repo-default.voidlinux.org",
    ])

    static let all: [DistributionMirror] = [
        official,
        DistributionMirror(id: "cn-tuna", name: "TUNA", region: .cn, endpoints: [
            .lxc("https://mirrors.tuna.tsinghua.edu.cn/lxc-images", index: "meta/simplestreams/v1/images.json"),
            .gentoo("https://mirrors.tuna.tsinghua.edu.cn/gentoo"),
            .void("https://mirrors.tuna.tsinghua.edu.cn/voidlinux"),
        ], packages: [
            .alpine: "https://mirrors.tuna.tsinghua.edu.cn/alpine",
            .arch: "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm",
            .centos: "https://mirrors.tuna.tsinghua.edu.cn/centos-stream",
            .debian: .init(
                "https://mirrors.tuna.tsinghua.edu.cn/debian",
                security: "https://mirrors.tuna.tsinghua.edu.cn/debian-security"
            ),
            .devuan: "https://mirrors.tuna.tsinghua.edu.cn/devuan/merged",
            .fedora: "https://mirrors.tuna.tsinghua.edu.cn/fedora",
            .gentoo: "https://mirrors.tuna.tsinghua.edu.cn/gentoo",
            .kali: "https://mirrors.tuna.tsinghua.edu.cn/kali",
            .nixos: "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store",
            .openEuler: "https://mirrors.tuna.tsinghua.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.tuna.tsinghua.edu.cn/opensuse", tumbleweed: true),
            .ubuntu: "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports",
            .void: "https://mirrors.tuna.tsinghua.edu.cn/voidlinux",
        ]),
        DistributionMirror(id: "cn-nju", name: "NJU", region: .cn, endpoints: [
            .lxc("https://mirrors.nju.edu.cn/lxc-images", index: "meta/simplestreams/v1/images.json"),
            .gentoo("https://mirrors.nju.edu.cn/gentoo"),
            .void("https://mirrors.nju.edu.cn/voidlinux"),
        ], packages: [
            .alma: "https://mirrors.nju.edu.cn/almalinux",
            .alpine: "https://mirrors.nju.edu.cn/alpine",
            .arch: "https://mirrors.nju.edu.cn/archlinuxarm",
            .centos: "https://mirrors.nju.edu.cn/centos-stream",
            .debian: .init("https://mirrors.nju.edu.cn/debian", security: "https://mirrors.nju.edu.cn/debian-security"),
            .devuan: "https://mirrors.nju.edu.cn/devuan/merged",
            .gentoo: "https://mirrors.nju.edu.cn/gentoo",
            .kali: "https://mirrors.nju.edu.cn/kali",
            .openEuler: "https://mirrors.nju.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.nju.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.nju.edu.cn/rocky",
            .ubuntu: "https://mirrors.nju.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-huawei", name: "Huawei Cloud", region: .cn, endpoints: [
            .gentoo("https://mirrors.huaweicloud.com/gentoo"),
        ], packages: [
            .alma: "https://mirrors.huaweicloud.com/almalinux",
            .alpine: "https://mirrors.huaweicloud.com/alpine",
            .centos: "https://mirrors.huaweicloud.com/centos-stream",
            .debian: .init(
                "https://mirrors.huaweicloud.com/debian",
                security: "https://mirrors.huaweicloud.com/debian-security"
            ),
            .fedora: "https://mirrors.huaweicloud.com/fedora",
            .gentoo: "https://mirrors.huaweicloud.com/gentoo",
            .kali: "https://mirrors.huaweicloud.com/kali",
            .openEuler: "https://mirrors.huaweicloud.com/openeuler",
            .openSUSE: "https://mirrors.huaweicloud.com/opensuse",
            .rocky: "https://mirrors.huaweicloud.com/rockylinux",
            .ubuntu: "https://mirrors.huaweicloud.com/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-nyist", name: "NYIST", region: .cn, endpoints: [
            .lxc("https://mirror.nyist.edu.cn/lxc-images", index: "meta/simplestreams/v1/images.json"),
        ], packages: [
            .alma: "https://mirror.nyist.edu.cn/almalinux",
            .alpine: "https://mirror.nyist.edu.cn/alpine",
            .arch: "https://mirror.nyist.edu.cn/archlinuxarm",
            .centos: "https://mirror.nyist.edu.cn/centos-stream",
            .debian: .init("https://mirror.nyist.edu.cn/debian", security: "https://mirror.nyist.edu.cn/debian-security"),
            .fedora: "https://mirror.nyist.edu.cn/fedora",
            .kali: "https://mirror.nyist.edu.cn/kali",
            .nixos: "https://mirror.nyist.edu.cn/nix-channels/store",
            .openSUSE: "https://mirror.nyist.edu.cn/opensuse",
            .rocky: "https://mirror.nyist.edu.cn/rocky",
            .ubuntu: "https://mirror.nyist.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-sjtug", name: "SJTUG", region: .cn, endpoints: [
            .void("https://mirrors.sjtug.sjtu.edu.cn/voidlinux"),
        ], packages: [
            .alma: "https://mirrors.sjtug.sjtu.edu.cn/almalinux",
            .alpine: "https://mirrors.sjtug.sjtu.edu.cn/alpine",
            .arch: "https://mirrors.sjtug.sjtu.edu.cn/archlinuxarm",
            .debian: .init(
                "https://mirrors.sjtug.sjtu.edu.cn/debian",
                security: "https://mirrors.sjtug.sjtu.edu.cn/debian-security"
            ),
            .fedora: "https://mirrors.sjtug.sjtu.edu.cn/fedora/linux",
            .kali: "https://mirrors.sjtug.sjtu.edu.cn/kali",
            .nixos: "https://mirrors.sjtug.sjtu.edu.cn/nix-channels/store",
            .openEuler: "https://mirrors.sjtug.sjtu.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.sjtug.sjtu.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.sjtug.sjtu.edu.cn/rocky",
            .ubuntu: "https://mirrors.sjtug.sjtu.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-zju", name: "ZJU", region: .cn, endpoints: [
            .gentoo("https://mirrors.zju.edu.cn/gentoo"),
            .void("https://mirrors.zju.edu.cn/voidlinux"),
        ], packages: [
            .alma: "https://mirrors.zju.edu.cn/almalinux",
            .alpine: "https://mirrors.zju.edu.cn/alpine",
            .arch: "https://mirrors.zju.edu.cn/archlinuxarm",
            .centos: "https://mirrors.zju.edu.cn/centos-stream",
            .debian: .init("https://mirrors.zju.edu.cn/debian", security: "https://mirrors.zju.edu.cn/debian-security"),
            .fedora: "https://mirrors.zju.edu.cn/fedora",
            .gentoo: "https://mirrors.zju.edu.cn/gentoo",
            .kali: "https://mirrors.zju.edu.cn/kali",
            .nixos: "https://mirrors.zju.edu.cn/nix-channels/store",
            .openEuler: "https://mirrors.zju.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.zju.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.zju.edu.cn/rocky",
            .ubuntu: "https://mirrors.zju.edu.cn/ubuntu-ports",
            .void: "https://mirrors.zju.edu.cn/voidlinux",
        ]),
        DistributionMirror(id: "cn-ustc", name: "USTC", region: .cn, endpoints: [
            .gentoo("https://mirrors.ustc.edu.cn/gentoo"),
        ], packages: [
            .alpine: "https://mirrors.ustc.edu.cn/alpine",
            .arch: "https://mirrors.ustc.edu.cn/archlinuxarm",
            .centos: "https://mirrors.ustc.edu.cn/centos-stream",
            .debian: .init("https://mirrors.ustc.edu.cn/debian", security: "https://mirrors.ustc.edu.cn/debian-security"),
            .fedora: "https://mirrors.ustc.edu.cn/fedora",
            .gentoo: "https://mirrors.ustc.edu.cn/gentoo",
            .kali: "https://mirrors.ustc.edu.cn/kali",
            .openEuler: "https://mirrors.ustc.edu.cn/openeuler",
            .openSUSE: "https://mirrors.ustc.edu.cn/opensuse",
            .rocky: "https://mirrors.ustc.edu.cn/rocky",
            .ubuntu: "https://mirrors.ustc.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-hernet", name: "HERNET", region: .cn, endpoints: [
            .lxc("https://mirrors.ha.edu.cn/lxc-images", index: "meta/simplestreams/v1/images.json"),
        ], packages: [
            .alma: "https://mirrors.ha.edu.cn/almalinux",
            .alpine: "https://mirrors.ha.edu.cn/alpine",
            .arch: "https://mirrors.ha.edu.cn/archlinuxarm",
            .centos: "https://mirrors.ha.edu.cn/centos-stream",
            .debian: .init("https://mirrors.ha.edu.cn/debian", security: "https://mirrors.ha.edu.cn/debian-security"),
            .fedora: "https://mirrors.ha.edu.cn/fedora",
            .kali: "https://mirrors.ha.edu.cn/kali",
            .nixos: "https://mirrors.ha.edu.cn/nix-channels/store",
            .openEuler: "https://mirrors.ha.edu.cn/openeuler",
            .openSUSE: "https://mirrors.ha.edu.cn/opensuse",
            .rocky: "https://mirrors.ha.edu.cn/rocky",
            .ubuntu: "https://mirrors.ha.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-sdu", name: "SDU", region: .cn, endpoints: [
            .lxc("https://mirrors.sdu.edu.cn/lxc-images", index: "meta/simplestreams/v1/images.json"),
            .gentoo("https://mirrors.sdu.edu.cn/gentoo"),
        ], packages: [
            .alpine: "https://mirrors.sdu.edu.cn/alpine",
            .debian: .init("https://mirrors.sdu.edu.cn/debian", security: "https://mirrors.sdu.edu.cn/debian-security"),
            .gentoo: "https://mirrors.sdu.edu.cn/gentoo",
            .kali: "https://mirrors.sdu.edu.cn/kali",
            .rocky: "https://mirrors.sdu.edu.cn/rocky",
            .ubuntu: "https://mirrors.sdu.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-lzu", name: "LZU", region: .cn, endpoints: [
            .gentoo("https://mirrors.lzu.edu.cn/gentoo"),
        ], packages: [
            .alma: "https://mirrors.lzu.edu.cn/almalinux",
            .alpine: "https://mirrors.lzu.edu.cn/alpine",
            .arch: "https://mirrors.lzu.edu.cn/archlinuxarm",
            .centos: "https://mirrors.lzu.edu.cn/centos-stream",
            .debian: .init("https://mirrors.lzu.edu.cn/debian", security: "https://mirrors.lzu.edu.cn/debian-security"),
            .fedora: "https://mirrors.lzu.edu.cn/fedora",
            .gentoo: "https://mirrors.lzu.edu.cn/gentoo",
            .kali: "https://mirrors.lzu.edu.cn/kali",
            .openEuler: "https://mirrors.lzu.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.lzu.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.lzu.edu.cn/rocky",
            .ubuntu: "https://mirrors.lzu.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-bfsu", name: "BFSU", region: .cn, endpoints: [
            .void("https://mirrors.bfsu.edu.cn/voidlinux"),
        ], packages: [
            .arch: "https://mirrors.bfsu.edu.cn/archlinuxarm",
            .centos: "https://mirrors.bfsu.edu.cn/centos-stream",
            .debian: .init("https://mirrors.bfsu.edu.cn/debian", security: "https://mirrors.bfsu.edu.cn/debian-security"),
            .fedora: "https://mirrors.bfsu.edu.cn/fedora",
            .kali: "https://mirrors.bfsu.edu.cn/kali",
            .openSUSE: .init("https://mirrors.bfsu.edu.cn/opensuse", tumbleweed: true),
            .void: "https://mirrors.bfsu.edu.cn/voidlinux",
        ]),
        DistributionMirror(id: "cn-pku", name: "PKU", region: .cn, endpoints: [], packages: [
            .alma: "https://mirrors.pku.edu.cn/almalinux",
            .centos: "https://mirrors.pku.edu.cn/centos-stream",
            .debian: .init("https://mirrors.pku.edu.cn/debian", security: "https://mirrors.pku.edu.cn/debian-security"),
            .openEuler: "https://mirrors.pku.edu.cn/openeuler",
            .openSUSE: .init("https://mirrors.pku.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.pku.edu.cn/rocky",
            .ubuntu: "https://mirrors.pku.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-sustech", name: "SUSTech", region: .cn, endpoints: [
            .gentoo("https://mirrors.sustech.edu.cn/gentoo"),
        ], packages: [
            .arch: "https://mirrors.sustech.edu.cn/archlinux-arm",
            .debian: .init(
                "https://mirrors.sustech.edu.cn/debian",
                security: "https://mirrors.sustech.edu.cn/debian-security"
            ),
            .fedora: "https://mirrors.sustech.edu.cn/fedora",
            .gentoo: "https://mirrors.sustech.edu.cn/gentoo",
            .kali: "https://mirrors.sustech.edu.cn/kali",
            .openSUSE: .init("https://mirrors.sustech.edu.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.sustech.edu.cn/rocky-linux",
            .ubuntu: "https://mirrors.sustech.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-hit", name: "HIT", region: .cn, endpoints: [
            .gentoo("https://mirrors.hit.edu.cn/gentoo"),
        ], packages: [
            .alma: "https://mirrors.hit.edu.cn/almalinux",
            .alpine: "https://mirrors.hit.edu.cn/alpine",
            .arch: "https://mirrors.hit.edu.cn/archlinuxarm",
            .centos: "https://mirrors.hit.edu.cn/centos-stream",
            .debian: "https://mirrors.hit.edu.cn/debian",
            .fedora: "https://mirrors.hit.edu.cn/fedora",
            .gentoo: "https://mirrors.hit.edu.cn/gentoo",
            .kali: "https://mirrors.hit.edu.cn/kali",
            .openEuler: "https://mirrors.hit.edu.cn/openeuler",
            .openSUSE: "https://mirrors.hit.edu.cn/opensuse",
            .ubuntu: "https://mirrors.hit.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-hust", name: "HUST", region: .cn, endpoints: [
            .gentoo("https://mirrors.hust.edu.cn/gentoo"),
        ], packages: [
            .alpine: "https://mirrors.hust.edu.cn/alpine",
            .debian: .init("https://mirrors.hust.edu.cn/debian", security: "https://mirrors.hust.edu.cn/debian-security"),
            .gentoo: "https://mirrors.hust.edu.cn/gentoo",
            .kali: "https://mirrors.hust.edu.cn/kali",
            .openEuler: "https://mirrors.hust.edu.cn/openeuler",
            .rocky: "https://mirrors.hust.edu.cn/rocky",
            .ubuntu: "https://mirrors.hust.edu.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-aliyun", name: "Alibaba Cloud", region: .cn, endpoints: [
            .gentoo("https://mirrors.aliyun.com/gentoo"),
        ], packages: [
            .alma: "https://mirrors.aliyun.com/almalinux",
            .alpine: "https://mirrors.aliyun.com/alpine",
            .arch: "https://mirrors.aliyun.com/archlinuxarm",
            .centos: "https://mirrors.aliyun.com/centos-stream",
            .debian: .init("https://mirrors.aliyun.com/debian", security: "https://mirrors.aliyun.com/debian-security"),
            .fedora: "https://mirrors.aliyun.com/fedora",
            .gentoo: "https://mirrors.aliyun.com/gentoo",
            .kali: "https://mirrors.aliyun.com/kali",
            .openEuler: "https://mirrors.aliyun.com/openeuler",
            .openSUSE: "https://mirrors.aliyun.com/opensuse",
            .rocky: "https://mirrors.aliyun.com/rockylinux",
            .ubuntu: "https://mirrors.aliyun.com/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-tencent", name: "Tencent Cloud", region: .cn, endpoints: [
            .gentoo("https://mirrors.tencent.com/gentoo"),
        ], packages: [
            .alma: "https://mirrors.tencent.com/almalinux",
            .alpine: "https://mirrors.tencent.com/alpine",
            .centos: "https://mirrors.tencent.com/centos-stream",
            .debian: .init("https://mirrors.tencent.com/debian", security: "https://mirrors.tencent.com/debian-security"),
            .fedora: "https://mirrors.tencent.com/fedora",
            .gentoo: "https://mirrors.tencent.com/gentoo",
            .openEuler: "https://mirrors.tencent.com/openeuler",
            .openSUSE: "https://mirrors.tencent.com/opensuse",
            .rocky: "https://mirrors.tencent.com/rocky",
            .ubuntu: "https://mirrors.tencent.com/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-volcengine", name: "Volcengine", region: .cn, endpoints: [], packages: [
            .alma: "https://mirrors.volces.com/almalinux",
            .alpine: "https://mirrors.volces.com/alpine",
            .centos: "https://mirrors.volces.com/centos-stream",
            .debian: .init("https://mirrors.volces.com/debian", security: "https://mirrors.volces.com/debian-security"),
            .fedora: "https://mirrors.volces.com/fedora/linux",
            .kali: "https://mirrors.volces.com/kali",
            .openEuler: "https://mirrors.volces.com/openeuler",
            .openSUSE: .init("https://mirrors.volces.com/opensuse", releases: ["16.0"]),
            .rocky: "https://mirrors.volces.com/rockylinux",
            .ubuntu: "https://mirrors.volces.com/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-ctyun", name: "CTYun", region: .cn, endpoints: [], packages: [
            .arch: "https://mirrors.ctyun.cn/archlinux-arm",
            .centos: "https://mirrors.ctyun.cn/centos-stream",
            .debian: .init("https://mirrors.ctyun.cn/debian", security: "https://mirrors.ctyun.cn/debian-security"),
            .fedora: "https://mirrors.ctyun.cn/fedora",
            .openEuler: "https://mirrors.ctyun.cn/openeuler",
            .openSUSE: .init("https://mirrors.ctyun.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.ctyun.cn/rocky",
            .ubuntu: "https://mirrors.ctyun.cn/ubuntu-ports",
        ]),
        DistributionMirror(id: "cn-cmecloud", name: "China Mobile Cloud", region: .cn, endpoints: [], packages: [
            .openEuler: "https://mirrors.cmecloud.cn/openeuler",
            .openSUSE: .init("https://mirrors.cmecloud.cn/opensuse", tumbleweed: true),
            .rocky: "https://mirrors.cmecloud.cn/rocky",
        ]),
        DistributionMirror(id: "sg-lxc", name: "Linux Containers (SG)", region: .apac, endpoints: [
            .lxc("https://sgp1mirror01.do.images.linuxcontainers.org"),
        ]),
        DistributionMirror(id: "sg-freedif", name: "Freedif (SG)", region: .apac, endpoints: [
            .gentoo("https://mirror.freedif.org/gentoo"),
            .void("https://mirror.freedif.org/voidlinux"),
        ], packages: [
            .alma: "https://mirror.freedif.org/almalinux",
            .alpine: "https://mirror.freedif.org/alpine",
            .centos: "https://mirror.freedif.org/CentOS",
            .debian: "https://mirror.freedif.org/debian",
            .fedora: "https://mirror.freedif.org/fedora/fedora/linux",
            .gentoo: "https://mirror.freedif.org/gentoo",
            .kali: "https://mirror.freedif.org/kali",
            .openSUSE: "https://mirror.freedif.org/opensuse",
            .rocky: "https://mirror.freedif.org/rocky",
            .void: "https://mirror.freedif.org/voidlinux",
        ]),
        DistributionMirror(id: "jp-iij", name: "IIJ (JP)", region: .apac, endpoints: [
            .gentoo("https://ftp.iij.ad.jp/pub/linux/gentoo"),
        ], packages: [
            .alma: "https://ftp.iij.ad.jp/pub/linux/almalinux",
            .centos: "https://ftp.iij.ad.jp/pub/linux/centos-stream",
            .debian: "https://ftp.iij.ad.jp/pub/linux/debian",
            .fedora: .init("https://ftp.iij.ad.jp/pub/linux/fedora/fedora/linux", releases: ["43"]),
            .gentoo: "https://ftp.iij.ad.jp/pub/linux/gentoo",
            .rocky: "https://ftp.iij.ad.jp/pub/linux/rocky",
        ]),
        DistributionMirror(id: "kr-mirror", name: "Lanet / Heigou (KR)", region: .apac, endpoints: [
            .gentoo("https://ftp.lanet.kr/pub/gentoo"),
            .void("https://mirror.heigou.pe.kr/voidlinux"),
        ], packages: [
            .gentoo: "https://ftp.lanet.kr/pub/gentoo",
            .void: "https://mirror.heigou.pe.kr/voidlinux",
        ]),
        DistributionMirror(id: "hk-cicku", name: "CICKU (HK)", region: .apac, endpoints: [
            .gentoo("https://hk.mirrors.cicku.me/gentoo"),
        ], packages: [
            .alma: "https://hk.mirrors.cicku.me/almalinux",
            .alpine: "https://hk.mirrors.cicku.me/alpine",
            .arch: "https://hk.mirrors.cicku.me/archlinuxarm",
            .fedora: "https://hk.mirrors.cicku.me/fedora/linux",
            .gentoo: "https://hk.mirrors.cicku.me/gentoo",
            .kali: "https://hk.mirrors.cicku.me/kali",
            .openEuler: "https://hk.mirrors.cicku.me/openeuler",
            .rocky: "https://hk.mirrors.cicku.me/rocky",
            .void: "https://hk.mirrors.cicku.me/voidlinux",
        ]),
        DistributionMirror(id: "tw-cicku", name: "CICKU (TW)", region: .apac, endpoints: [
            .gentoo("https://tw.mirrors.cicku.me/gentoo"),
        ], packages: [
            .alma: "https://tw.mirrors.cicku.me/almalinux",
            .alpine: "https://tw.mirrors.cicku.me/alpine",
            .arch: "https://tw.mirrors.cicku.me/archlinuxarm",
            .fedora: "https://tw.mirrors.cicku.me/fedora/linux",
            .gentoo: "https://tw.mirrors.cicku.me/gentoo",
            .kali: "https://tw.mirrors.cicku.me/kali",
            .openEuler: "https://tw.mirrors.cicku.me/openeuler",
            .rocky: "https://tw.mirrors.cicku.me/rocky",
            .void: "https://tw.mirrors.cicku.me/voidlinux",
        ]),
        DistributionMirror(id: "au-mirror", name: "Linux Containers / AARNet (AU)", region: .apac, endpoints: [
            .lxc("https://syd1mirror01.do.images.linuxcontainers.org"),
            .void("https://mirror.aarnet.edu.au/pub/voidlinux"),
        ], packages: [
            .alma: "https://mirror.aarnet.edu.au/pub/almalinux",
            .alpine: "https://mirror.aarnet.edu.au/pub/alpine",
            .centos: "https://mirror.aarnet.edu.au/pub/centos-stream",
            .debian: .init("https://mirror.aarnet.edu.au/pub/debian", security: "https://mirror.aarnet.edu.au/pub/debian-security"),
            .devuan: "https://mirror.aarnet.edu.au/pub/devuan/merged",
            .fedora: "https://mirror.aarnet.edu.au/pub/fedora/linux",
            .gentoo: "https://mirror.aarnet.edu.au/pub/gentoo",
            .openSUSE: "https://mirror.aarnet.edu.au/pub/opensuse",
            .rocky: "https://mirror.aarnet.edu.au/pub/rocky",
            .void: "https://mirror.aarnet.edu.au/pub/voidlinux",
        ]),
        DistributionMirror(id: "in-lxc", name: "Linux Containers (IN)", region: .apac, endpoints: [
            .lxc("https://blr1mirror01.do.images.linuxcontainers.org"),
        ]),
        DistributionMirror(id: "us-sfo", name: "Linux Containers (US)", region: .na, endpoints: [
            .lxc("https://sfo3mirror01.do.images.linuxcontainers.org"),
        ]),
        DistributionMirror(id: "us-osuosl", name: "OSUOSL / Summit (US)", region: .na, endpoints: [
            .gentoo("https://gentoo.osuosl.org"),
            .void("https://mirrors.summithq.com/voidlinux"),
        ], packages: [
            .alma: "https://almalinux.osuosl.org",
            .centos: "https://centos-stream.osuosl.org",
            .debian: "https://debian.osuosl.org/debian",
            .fedora: "https://fedora.osuosl.org/linux",
            .gentoo: "https://gentoo.osuosl.org",
            .void: "https://mirrors.summithq.com/voidlinux",
        ]),
        DistributionMirror(id: "ca-mirror", name: "Linux Containers / Waterloo (CA)", region: .na, endpoints: [
            .lxc("https://ca.images.linuxcontainers.org", index: "streams/v1/images.json"),
            .gentoo("https://mirror.csclub.uwaterloo.ca/gentoo-distfiles"),
            .void("https://void.tuxmirrors.xyz"),
        ], packages: [
            .alma: "https://mirror.csclub.uwaterloo.ca/almalinux",
            .alpine: "https://mirror.csclub.uwaterloo.ca/alpine",
            .arch: "https://mirror.csclub.uwaterloo.ca/archlinuxarm",
            .debian: .init(
                "https://mirror.csclub.uwaterloo.ca/debian",
                security: "https://mirror.csclub.uwaterloo.ca/debian-security"
            ),
            .fedora: "https://mirror.csclub.uwaterloo.ca/fedora/linux",
            .gentoo: "https://mirror.csclub.uwaterloo.ca/gentoo-distfiles",
            .openSUSE: "https://mirror.csclub.uwaterloo.ca/opensuse",
            .rocky: "https://mirror.csclub.uwaterloo.ca/rocky",
            .ubuntu: "https://mirror.csclub.uwaterloo.ca/ubuntu-ports",
            .void: "https://void.tuxmirrors.xyz",
        ]),
        DistributionMirror(id: "de-fra", name: "Linux Containers / FAU (DE)", region: .eu, endpoints: [
            .lxc("https://fra1mirror01.do.images.linuxcontainers.org"),
            .gentoo("https://ftp.fau.de/gentoo"),
            .void("https://repo-de.voidlinux.org"),
        ], packages: [
            .alma: "https://ftp.fau.de/almalinux",
            .debian: "https://ftp.fau.de/debian",
            .devuan: "https://ftp.fau.de/devuan/merged",
            .fedora: "https://ftp.fau.de/fedora/linux",
            .gentoo: "https://ftp.fau.de/gentoo",
            .openSUSE: "https://ftp.fau.de/opensuse",
            .rocky: "https://ftp.fau.de/rockylinux",
            .ubuntu: "https://ftp.fau.de/ubuntu-ports",
            .void: "https://repo-de.voidlinux.org",
        ]),
        DistributionMirror(id: "nl-utwente", name: "UTwente (NL)", region: .eu, endpoints: [
            .gentoo("https://ftp.snt.utwente.nl/pub/os/linux/gentoo"),
        ], packages: [
            .debian: .init(
                "https://ftp.snt.utwente.nl/pub/os/linux/debian",
                security: "https://ftp.snt.utwente.nl/pub/os/linux/debian-security"
            ),
            .gentoo: "https://ftp.snt.utwente.nl/pub/os/linux/gentoo",
        ]),
        DistributionMirror(id: "se-lysator", name: "Lysator (SE)", region: .eu, endpoints: [
            .gentoo("https://ftp.lysator.liu.se/gentoo"),
            .void("https://ftp.lysator.liu.se/pub/voidlinux"),
        ], packages: [
            .alma: "https://ftp.lysator.liu.se/pub/almalinux",
            .alpine: "https://ftp.lysator.liu.se/pub/alpine",
            .debian: .init("https://ftp.lysator.liu.se/pub/debian", security: "https://ftp.lysator.liu.se/pub/debian-security"),
            .fedora: "https://ftp.lysator.liu.se/pub/fedora/linux",
            .gentoo: "https://ftp.lysator.liu.se/gentoo",
            .rocky: "https://ftp.lysator.liu.se/pub/rocky",
            .void: "https://ftp.lysator.liu.se/pub/voidlinux",
        ]),
        DistributionMirror(id: "fi-void", name: "Void (FI)", region: .eu, endpoints: [
            .void("https://repo-fi.voidlinux.org"),
        ], packages: [
            .void: "https://repo-fi.voidlinux.org",
        ]),
        DistributionMirror(id: "gb-mirror", name: "UK Mirror Service (GB)", region: .eu, endpoints: [
            .gentoo("https://www.mirrorservice.org/sites/distfiles.gentoo.org"),
        ], packages: [
            .alma: "https://www.mirrorservice.org/sites/repo.almalinux.org/almalinux",
            .centos: "https://www.mirrorservice.org/sites/mirror.stream.centos.org",
            .debian: "https://www.mirrorservice.org/sites/ftp.debian.org/debian",
            .fedora: "https://www.mirrorservice.org/sites/dl.fedoraproject.org/pub/fedora/linux",
            .gentoo: "https://www.mirrorservice.org/sites/distfiles.gentoo.org",
            .rocky: "https://www.mirrorservice.org/sites/download.rockylinux.org/pub/rocky",
        ]),
    ]
}

nonisolated enum DistributionMirrorRouter {
    struct Candidate: Sendable {
        let endpoint: MirrorEndpoint
        let url: URL
    }

    static let regionDetector = MirrorRegionDetector()

    static func endpoints(for repository: MirrorRepository, preferring mirror: DistributionMirror?) async -> [MirrorEndpoint] {
        if let mirror, mirror.hosts(repository) {
            return mirror.endpoints(for: repository)
        }
        let region = await regionDetector.region()
        let regional = DistributionMirror.all.filter { $0.region == region }.flatMap { $0.endpoints(for: repository) }
        return regional.isEmpty ? DistributionMirror.official.endpoints(for: repository) : regional
    }

    static func firstSuccess<Result>(
        for repository: MirrorRepository,
        preferring mirror: DistributionMirror?,
        url: @escaping @Sendable (MirrorEndpoint) -> URL?,
        _ body: (Candidate) async throws -> Result
    ) async throws -> Result {
        var lastError: (any Error)?
        for await candidate in candidates(for: repository, preferring: mirror, url: url) {
            do {
                return try await body(candidate)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        try Task.checkCancellation()
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private static func candidates(
        for repository: MirrorRepository,
        preferring mirror: DistributionMirror?,
        url: @escaping @Sendable (MirrorEndpoint) -> URL?
    ) -> AsyncStream<Candidate> {
        AsyncStream { continuation in
            let task = Task {
                let pool = await endpoints(for: repository, preferring: mirror)
                if mirror?.hosts(repository) == true || pool == DistributionMirror.official.endpoints(for: repository) {
                    for endpoint in pool {
                        if let target = url(endpoint) {
                            continuation.yield(Candidate(endpoint: endpoint, url: target))
                        }
                    }
                } else {
                    await withTaskGroup(of: Candidate?.self) { group in
                        for endpoint in pool {
                            guard let target = url(endpoint) else { continue }
                            group.addTask {
                                await MirrorProbe.probe(target) != nil ? Candidate(endpoint: endpoint, url: target) : nil
                            }
                        }
                        for await candidate in group {
                            if let candidate {
                                continuation.yield(candidate)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

actor MirrorRegionDetector {
    private static let lifetime = Duration.seconds(300)

    private var detected: (region: MirrorRegion, at: ContinuousClock.Instant)?
    private var pending: Task<MirrorRegion, Never>?

    func region() async -> MirrorRegion {
        if let detected, detected.at.duration(to: .now) < Self.lifetime {
            return detected.region
        }
        if let pending {
            return await pending.value
        }
        let task = Task {
            await withTaskGroup(of: MirrorRegion?.self) { group in
                for region in MirrorRegion.allCases {
                    for url in region.probeURLs {
                        group.addTask {
                            await MirrorProbe.probe(url) != nil ? region : nil
                        }
                    }
                }
                for await region in group {
                    if let region {
                        group.cancelAll()
                        return region
                    }
                }
                return MirrorRegion.global
            }
        }
        pending = task
        let region = await task.value
        detected = (region, .now)
        pending = nil
        return region
    }
}

nonisolated enum MirrorProbe {
    struct Response: Sendable {
        let lastModified: Date?
        let latency: Duration
    }

    private static let httpDate = Date.ParseStrategy(
        format: """
        \(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT
        """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .gmt
    )

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()

    static func probe(_ url: URL) async -> Response? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("Swipterm/1.0", forHTTPHeaderField: "User-Agent")
        let start = ContinuousClock.now
        guard let (bytes, response) = try? await session.bytes(for: request) else {
            return nil
        }
        let latency = start.duration(to: .now)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206,
              http.mimeType?.lowercased() != "text/html"
        else {
            return nil
        }
        return Response(
            lastModified: http.value(forHTTPHeaderField: "Last-Modified").flatMap { try? Date($0, strategy: httpDate) },
            latency: latency
        )
    }
}
