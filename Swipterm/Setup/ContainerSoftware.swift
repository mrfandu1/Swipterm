import Foundation

nonisolated enum LoginShell: String, Codable, CaseIterable, Identifiable, Sendable {
    case ash
    case bash
    case zsh
    case fish
    case nushell

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .ash: "ash"
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .fish: "Fish"
        case .nushell: "Nushell"
        }
    }
}

nonisolated enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case password
    case publicKey
    case passwordAndPublicKey

    var allowsPassword: Bool {
        self != .publicKey
    }

    var allowsPublicKey: Bool {
        self != .password
    }
}

nonisolated struct SSHServer: Codable, Equatable, Sendable {
    static let defaultPort = 10022
    static let ports = 1024 ... 65535

    var port: Int
    var authentication: SSHAuthentication
    var authorizedKeys: String
}

nonisolated enum DeveloperTool: String, Codable, CaseIterable, Sendable {
    case node
    case pnpm
    case bun
    case go

    var displayName: String {
        switch self {
        case .node: "Node.js (npm)"
        case .pnpm: "pnpm"
        case .bun: "Bun"
        case .go: "Go"
        }
    }

    var shortName: String {
        switch self {
        case .node: "Node.js"
        case .pnpm: "pnpm"
        case .bun: "Bun"
        case .go: "Go"
        }
    }

    var isJavaScriptToolchain: Bool {
        self != .go
    }
}

nonisolated enum CodingAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case antigravity

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity CLI"
        }
    }

    var shortName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var isJavaScriptPackage: Bool {
        self != .antigravity
    }
}

nonisolated struct ContainerSoftware: Codable, Equatable, Sendable {
    var shell: LoginShell?
    var ssh: SSHServer?
    var developerTools: Set<DeveloperTool> = []
    var agents: Set<CodingAgent> = []

    var installedDeveloperTools: Set<DeveloperTool> {
        agents.contains(where: \.isJavaScriptPackage) ? developerTools.union([.node]) : developerTools
    }

    mutating func setDeveloperTool(_ tool: DeveloperTool, isEnabled: Bool) {
        if isEnabled {
            developerTools.insert(tool)
        } else {
            developerTools.remove(tool)
        }
        if !developerTools.contains(where: \.isJavaScriptToolchain) {
            agents = agents.filter { !$0.isJavaScriptPackage }
        }
    }

    mutating func setAgent(_ agent: CodingAgent, isEnabled: Bool) {
        guard isEnabled else {
            agents.remove(agent)
            return
        }
        agents.insert(agent)
        if agent.isJavaScriptPackage, !developerTools.contains(where: \.isJavaScriptToolchain) {
            developerTools.insert(.pnpm)
        }
    }
}

nonisolated extension LinuxDistribution {
    var defaultShell: LoginShell {
        self == .alpine ? .ash : .bash
    }

    func shells(for release: LinuxReleaseImage?) -> [LoginShell] {
        switch self {
        case .alpine:
            let version = release?.releaseKey.split(separator: ".").compactMap { Int($0) } ?? []
            let hasNushell = release?.releaseKey == "edge" || !version.lexicographicallyPrecedes([3, 22])
            return hasNushell ? [.ash, .bash, .zsh, .fish, .nushell] : [.ash, .bash, .zsh, .fish]
        case .alma, .centos, .oracle, .rocky:
            return [.bash, .zsh]
        case .debian, .devuan, .gentoo, .kali, .openEuler, .ubuntu:
            return [.bash, .zsh, .fish]
        case .arch, .fedora, .nixos, .openSUSE, .void:
            return [.bash, .zsh, .fish, .nushell]
        }
    }
}
