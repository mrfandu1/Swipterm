import Foundation

nonisolated enum PackageRegistry: String, Codable, CaseIterable, Sendable {
    case npm
    case go
    case pypi
    case crates

    var displayName: String {
        switch self {
        case .npm: "npm"
        case .go: "Go"
        case .pypi: "PyPI"
        case .crates: "crates.io"
        }
    }
}

nonisolated struct RegistryMirror: Identifiable, Sendable {
    let id: String
    let name: String
    let region: MirrorRegion
    let registry: PackageRegistry
    let url: String
    let distributionURL: String?

    static func mirrors(for registry: PackageRegistry) -> [RegistryMirror] {
        all.filter { $0.registry == registry }
    }

    static func resolve(_ registry: PackageRegistry, id: String?, usesChinaMirrors: Bool) -> RegistryMirror {
        let mirrors = mirrors(for: registry)
        if let id, let selected = mirrors.first(where: { $0.id == id }) {
            return selected
        }
        return mirrors.first { $0.region == (usesChinaMirrors ? .cn : .global) }!
    }

    private static let all: [RegistryMirror] = [
        RegistryMirror(
            id: "official", name: "Official", region: .global, registry: .npm,
            url: "https://registry.npmjs.org", distributionURL: "https://nodejs.org/dist"
        ),
        RegistryMirror(
            id: "npmmirror", name: "npmmirror", region: .cn, registry: .npm,
            url: "https://registry.npmmirror.com", distributionURL: "https://npmmirror.com/mirrors/node"
        ),
        RegistryMirror(
            id: "huawei", name: "Huawei Cloud", region: .cn, registry: .npm,
            url: "https://mirrors.huaweicloud.com/repository/npm", distributionURL: "https://mirrors.huaweicloud.com/nodejs"
        ),
        RegistryMirror(
            id: "tencent", name: "Tencent Cloud", region: .cn, registry: .npm,
            url: "https://mirrors.cloud.tencent.com/npm", distributionURL: "https://mirrors.cloud.tencent.com/nodejs-release"
        ),

        RegistryMirror(
            id: "official", name: "Official", region: .global, registry: .go,
            url: "https://proxy.golang.org", distributionURL: "https://go.dev/dl"
        ),
        RegistryMirror(
            id: "goproxy-cn", name: "Goproxy.cn", region: .cn, registry: .go,
            url: "https://goproxy.cn", distributionURL: "https://golang.google.cn/dl"
        ),
        RegistryMirror(
            id: "goproxy-io", name: "GOPROXY.IO", region: .cn, registry: .go,
            url: "https://goproxy.io", distributionURL: "https://golang.google.cn/dl"
        ),
        RegistryMirror(
            id: "aliyun", name: "Alibaba Cloud", region: .cn, registry: .go,
            url: "https://mirrors.aliyun.com/goproxy", distributionURL: "https://golang.google.cn/dl"
        ),
        RegistryMirror(
            id: "tencent", name: "Tencent Cloud", region: .cn, registry: .go,
            url: "https://mirrors.cloud.tencent.com/go", distributionURL: "https://golang.google.cn/dl"
        ),
        RegistryMirror(
            id: "huawei", name: "Huawei Cloud", region: .cn, registry: .go,
            url: "https://repo.huaweicloud.com/repository/goproxy", distributionURL: "https://golang.google.cn/dl"
        ),

        RegistryMirror(
            id: "official", name: "Official", region: .global, registry: .pypi,
            url: "https://pypi.org/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "aliyun", name: "Alibaba Cloud", region: .cn, registry: .pypi,
            url: "https://mirrors.aliyun.com/pypi/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "tuna", name: "TUNA", region: .cn, registry: .pypi,
            url: "https://pypi.tuna.tsinghua.edu.cn/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "ustc", name: "USTC", region: .cn, registry: .pypi,
            url: "https://mirrors.ustc.edu.cn/pypi/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "bfsu", name: "BFSU", region: .cn, registry: .pypi,
            url: "https://mirrors.bfsu.edu.cn/pypi/web/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "nju", name: "NJU", region: .cn, registry: .pypi,
            url: "https://mirror.nju.edu.cn/pypi/web/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "sjtug", name: "SJTUG", region: .cn, registry: .pypi,
            url: "https://mirrors.sjtug.sjtu.edu.cn/pypi/web/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "tencent", name: "Tencent Cloud", region: .cn, registry: .pypi,
            url: "https://mirrors.cloud.tencent.com/pypi/simple", distributionURL: nil
        ),
        RegistryMirror(
            id: "huawei", name: "Huawei Cloud", region: .cn, registry: .pypi,
            url: "https://mirrors.huaweicloud.com/repository/pypi/simple", distributionURL: nil
        ),

        RegistryMirror(
            id: "official", name: "Official", region: .global, registry: .crates,
            url: "https://index.crates.io", distributionURL: "https://static.rust-lang.org"
        ),
        RegistryMirror(
            id: "rsproxy", name: "RsProxy", region: .cn, registry: .crates,
            url: "https://rsproxy.cn/index", distributionURL: "https://rsproxy.cn"
        ),
        RegistryMirror(
            id: "ustc", name: "USTC", region: .cn, registry: .crates,
            url: "https://mirrors.ustc.edu.cn/crates.io-index", distributionURL: "https://mirrors.ustc.edu.cn/rust-static"
        ),
        RegistryMirror(
            id: "sjtug", name: "SJTUG", region: .cn, registry: .crates,
            url: "https://mirrors.sjtug.sjtu.edu.cn/crates.io-index", distributionURL: "https://mirrors.sjtug.sjtu.edu.cn/rust-static"
        ),
    ]
}
