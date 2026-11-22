import Foundation
import SwiptermKit

nonisolated struct PackageRepositoryConfigurator {
    let fileSystem: LinuxFileSystem
    let distribution: LinuxDistribution
    let release: OSRelease

    private static let archBrokenServer = "http://mirror.archlinuxarm.org/$arch/$repo"
    private static let oracleKeyPath = "/etc/pki/rpm-gpg/RPM-GPG-KEY-oracle"

    func apply(_ source: PackageSource) async throws -> [String] {
        let root: PackageRepositoryRoot? = switch source {
        case .upstream: nil
        case let .mirror(_, root): root
        }
        switch distribution {
        case .debian, .devuan, .kali, .ubuntu:
            guard let root else { return [] }
            return try await configureAPT(root)
        case .alpine:
            guard let root else { return [] }
            return try await rewrite(["/etc/apk/repositories"]) { RepositoryText.alpine($0, root: root.url) }
        case .arch:
            return try await rewrite(["/etc/pacman.d/mirrorlist"]) { text in
                if let root {
                    return RepositoryText.pacmanMirrorlist(text, server: "\(root.url)/$arch/$repo")
                }
                return RepositoryText.pacmanReplacing(
                    text,
                    server: Self.archBrokenServer,
                    with: "\(DistributionMirror.official.packages[.arch]!.url)/$arch/$repo"
                )
            }
        case .fedora:
            guard let root else { return [] }
            return try await configureFedora(root)
        case .alma, .rocky:
            guard let root else { return [] }
            return try await rewriteRepoFiles { RepositoryText.repoStanzas($0) { id in
                Self.enterpriseLinuxPath(id).map { "\(root.url)/\($0)" }
            } }
        case .centos:
            guard let root else { return [] }
            return try await rewriteRepoFiles { RepositoryText.repoStanzas($0) { id in
                Self.centOSPath(id).map { "\(root.url)/\($0)" }
            } }
        case .openEuler:
            guard let root else { return [] }
            return try await rewriteRepoFiles { RepositoryText.openEuler($0, root: root.url) }
        case .oracle:
            guard await exists(Self.oracleKeyPath) else { return [] }
            return try await rewriteRepoFiles(RepositoryText.oracleKeyPath)
        case .openSUSE:
            guard let root else { return [] }
            return try await configureZypper(root)
        case .void:
            guard let root else { return [] }
            return try await configureXBPS(root)
        case .gentoo:
            guard let root else { return [] }
            return try await configurePortage(root)
        case .nixos:
            return []
        }
    }

    private func configureAPT(_ root: PackageRepositoryRoot) async throws -> [String] {
        let distribution = distribution
        let replacement: (String) -> String? = { uri in
            let component = RepositoryText.lastPathComponent(of: uri)
            switch distribution {
            case .ubuntu:
                return component == "ubuntu-ports" || component == "ubuntu" ? root.url : nil
            case .debian:
                if component == "debian-security" {
                    return root.securityURL
                }
                return component == "debian" ? root.url : nil
            case .kali:
                return component == "kali" ? root.url : nil
            case .devuan:
                return component == "merged" ? root.url : nil
            default:
                return nil
            }
        }
        let directory = "/etc/apt/sources.list.d"
        let entries = await regularFiles(in: directory)
        var changed = try await rewrite(["/etc/apt/sources.list"] + entries.filter { $0.hasSuffix(".list") }.map { "\(directory)/\($0)" }) {
            RepositoryText.sourcesList($0, replacing: replacement)
        }
        changed += try await rewrite(entries.filter { $0.hasSuffix(".sources") }.map { "\(directory)/\($0)" }) {
            RepositoryText.deb822($0, replacing: replacement)
        }
        return changed
    }

    private func configureFedora(_ root: PackageRepositoryRoot) async throws -> [String] {
        let transform: (String) -> String = { text in
            RepositoryText.repoStanzas(text) { id in
                switch id {
                case "fedora": "\(root.url)/releases/$releasever/Everything/$basearch/os/"
                case "updates": "\(root.url)/updates/$releasever/Everything/$basearch/"
                default: nil
                }
            }
        }
        var changed: [String] = []
        for name in ["fedora.repo", "fedora-updates.repo"] {
            let override = "/etc/yum.repos.d/\(name)"
            if await exists(override) {
                changed += try await rewrite([override], transform)
                continue
            }
            let vendor = "/usr/share/dnf5/repos.d/\(name)"
            guard let text = try await read(vendor) else { continue }
            try await fileSystem.writeFile(override, contents: Data(transform(text).utf8), permissions: 0o644)
            changed.append(override)
        }
        return changed
    }

    private func configureZypper(_ root: PackageRepositoryRoot) async throws -> [String] {
        let prefixes = release.isTumbleweed
            ? ["/ports/aarch64/tumbleweed/", "/ports/aarch64/update/tumbleweed/"]
            : ["/distribution/leap/"]
        let directory = "/etc/zypp/repos.d"
        var changed = try await rewrite(await regularFiles(in: directory).filter { $0.hasSuffix(".repo") }.map { "\(directory)/\($0)" }) {
            RepositoryText.zypperRepo($0, root: root.url, prefixes: prefixes)
        }
        let services = "/etc/zypp/services.d"
        for name in await regularFiles(in: services) where name.hasSuffix(".service") {
            guard let text = try await read("\(services)/\(name)"),
                  let directory = RepositoryText.zypperServiceDirectory(text)
            else { continue }
            changed += try await rewrite(["\(directory)/repo/repoindex.xml"]) {
                RepositoryText.zypperRepoIndex($0, root: root.url, prefixes: prefixes)
            }
        }
        return changed
    }

    private func configureXBPS(_ root: PackageRepositoryRoot) async throws -> [String] {
        let override = "/etc/xbps.d/00-repository-main.conf"
        var text = try await read(override)
        if text == nil {
            text = try await read("/usr/share/xbps.d/00-repository-main.conf")
        }
        guard let text else { return [] }
        let updated = RepositoryText.xbpsRepositories(text, root: root.url)
        guard updated != text else { return [] }
        try await fileSystem.writeFile(override, contents: Data(updated.utf8), permissions: 0o644)
        return [override]
    }

    private func configurePortage(_ root: PackageRepositoryRoot) async throws -> [String] {
        var changed = try await rewrite(["/etc/portage/binrepos.conf/gentoo.conf"]) {
            RepositoryText.portageBinrepo($0, root: root.url)
        }
        changed += try await rewrite(["/etc/portage/make.conf"]) {
            RepositoryText.portageMirrors($0, root: root.url)
        }
        return changed
    }

    private func rewriteRepoFiles(_ transform: (String) -> String) async throws -> [String] {
        let directory = "/etc/yum.repos.d"
        let paths = await regularFiles(in: directory).filter { $0.hasSuffix(".repo") }.map { "\(directory)/\($0)" }
        return try await rewrite(paths, transform)
    }

    private func rewrite(_ paths: [String], _ transform: (String) -> String) async throws -> [String] {
        var changed: [String] = []
        for path in paths {
            guard let text = try await read(path) else { continue }
            var updated = transform(text)
            guard updated != text else { continue }
            if !updated.hasSuffix("\n") {
                updated.append("\n")
            }
            let permissions = try await fileSystem.stat(path).permissions
            try await fileSystem.writeFile(path, contents: Data(updated.utf8), permissions: permissions)
            changed.append(path)
        }
        return changed
    }

    private func read(_ path: String) async throws -> String? {
        do {
            return String(data: try await fileSystem.contents(of: path), encoding: .utf8)
        } catch let error as LinuxError where error == .ENOENT || error == .ENOTDIR {
            return nil
        }
    }

    private func exists(_ path: String) async -> Bool {
        (try? await fileSystem.stat(path)) != nil
    }

    private func regularFiles(in directory: String) async -> [String] {
        let entries = (try? await fileSystem.listDirectory(directory)) ?? []
        return entries.filter { $0.type == .regular }.map(\.name).sorted()
    }

    private static func enterpriseLinuxPath(_ id: String) -> String? {
        switch id {
        case "baseos": "$releasever/BaseOS/$basearch/os/"
        case "appstream": "$releasever/AppStream/$basearch/os/"
        case "extras": "$releasever/extras/$basearch/os/"
        case "crb": "$releasever/CRB/$basearch/os/"
        default: nil
        }
    }

    private static func centOSPath(_ id: String) -> String? {
        switch id {
        case "baseos": "$stream/BaseOS/$basearch/os/"
        case "appstream": "$stream/AppStream/$basearch/os/"
        case "crb": "$stream/CRB/$basearch/os/"
        case "extras-common": "SIGs/$stream/extras/$basearch/extras-common/"
        default: nil
        }
    }
}

private nonisolated enum RepositoryText {
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func lastPathComponent(of uri: String) -> String? {
        guard let path = path(of: uri) else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }

    static func path(of uri: String) -> Substring? {
        guard let scheme = uri.range(of: "://"),
              ["http", "https"].contains(uri[..<scheme.lowerBound].lowercased())
        else {
            return nil
        }
        let remainder = uri[scheme.upperBound...]
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        return remainder[slash...]
    }

    static func sourcesList(_ text: String, replacing replacement: (String) -> String?) -> String {
        lines(text).map { line in
            var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let type = tokens.first, type == "deb" || type == "deb-src" else { return line }
            var index = 1
            if index < tokens.count, tokens[index].hasPrefix("[") {
                while index < tokens.count, !tokens[index].hasSuffix("]") {
                    index += 1
                }
                index += 1
            }
            guard index < tokens.count, let uri = replacement(tokens[index]) else { return line }
            tokens[index] = uri
            return tokens.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func deb822(_ text: String, replacing replacement: (String) -> String?) -> String {
        lines(text).map { line in
            guard let separator = line.firstIndex(of: ":"),
                  line[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "uris"
            else {
                return line
            }
            let uris = line[line.index(after: separator)...].split(whereSeparator: \.isWhitespace).map(String.init)
            let replaced = uris.map { replacement($0) ?? $0 }
            return replaced == uris ? line : "URIs: \(replaced.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    static func alpine(_ text: String, root: String) -> String {
        lines(text).map { line in
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let scheme = line.range(of: "://"),
                  let branch = line.range(of: "/alpine/", range: scheme.upperBound ..< line.endIndex)
            else {
                return line
            }
            let start = line[..<scheme.lowerBound].lastIndex(where: \.isWhitespace).map(line.index(after:)) ?? line.startIndex
            return String(line[..<start]) + root + String(line[branch.lowerBound...].dropFirst("/alpine".count))
        }.joined(separator: "\n")
    }

    static func pacmanMirrorlist(_ text: String, server: String) -> String {
        let commented = lines(text).map { line in
            isPacmanServer(line) ? "#\(line)" : line
        }
        return (["Server = \(server)"] + commented).joined(separator: "\n")
    }

    static func pacmanReplacing(_ text: String, server: String, with replacement: String) -> String {
        lines(text).map { line in
            guard isPacmanServer(line),
                  let separator = line.firstIndex(of: "="),
                  line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces) == server
            else {
                return line
            }
            return "Server = \(replacement)"
        }.joined(separator: "\n")
    }

    private static func isPacmanServer(_ line: String) -> Bool {
        guard let separator = line.firstIndex(of: "=") else { return false }
        return line[..<separator].trimmingCharacters(in: .whitespaces) == "Server"
    }

    static func repoStanzas(_ text: String, baseURL: (String) -> String?) -> String {
        var output: [String] = []
        var rewriting = false
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                output.append(line)
                let url = baseURL(String(trimmed.dropFirst().dropLast()))
                rewriting = url != nil
                if let url {
                    output.append("baseurl=\(url)")
                }
                continue
            }
            if rewriting, let key = iniKey(trimmed), ["baseurl", "metalink", "mirrorlist"].contains(key) {
                output.append("#\(line)")
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    static func openEuler(_ text: String, root: String) -> String {
        lines(text).map { line in
            guard let key = iniKey(line), ["baseurl", "gpgkey"].contains(key),
                  let separator = line.firstIndex(of: "=")
            else {
                return line
            }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard path(of: value) != nil, let release = value.range(of: "/openEuler-") else { return line }
            return "\(line[..<separator])=\(root)\(value[release.lowerBound...])"
        }.joined(separator: "\n")
    }

    static func oracleKeyPath(_ text: String) -> String {
        lines(text).map { line in
            guard iniKey(line) == "gpgkey" else { return line }
            return line.replacingOccurrences(of: "file:///RPM-GPG-KEY-oracle", with: "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle")
        }.joined(separator: "\n")
    }

    static func zypperRepo(_ text: String, root: String, prefixes: [String]) -> String {
        lines(text).map { line in
            guard let key = iniKey(line), ["baseurl", "gpgkey"].contains(key),
                  let separator = line.firstIndex(of: "=")
            else {
                return line
            }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let path = path(of: value), prefixes.contains(where: { path.hasPrefix($0) }) else { return line }
            return "\(line[..<separator])=\(root)\(path)"
        }.joined(separator: "\n")
    }

    static func zypperServiceDirectory(_ text: String) -> String? {
        for line in lines(text) {
            guard iniKey(line) == "url", let separator = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("dir:") {
                return String(value.dropFirst("dir:".count))
            }
        }
        return nil
    }

    static func zypperRepoIndex(_ text: String, root: String, prefixes: [String]) -> String {
        prefixes.reduce(text) { text, prefix in
            text.replacingOccurrences(of: "\"%{disturl}\(prefix)", with: "\"\(root)\(prefix)")
        }
    }

    static func xbpsRepositories(_ text: String, root: String) -> String {
        lines(text).map { line in
            guard iniKey(line) == "repository", let separator = line.firstIndex(of: "=") else { return line }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard path(of: value) != nil, let current = value.range(of: "/current") else { return line }
            return "repository=\(root)\(value[current.lowerBound...])"
        }.joined(separator: "\n")
    }

    static func portageBinrepo(_ text: String, root: String) -> String {
        lines(text).map { line in
            guard iniKey(line) == "sync-uri", let separator = line.firstIndex(of: "=") else { return line }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard path(of: value) != nil, let releases = value.range(of: "/releases/") else { return line }
            return "sync-uri = \(root)\(value[releases.lowerBound...])"
        }.joined(separator: "\n")
    }

    static func portageMirrors(_ text: String, root: String) -> String {
        let assignment = "GENTOO_MIRRORS=\"\(root)\""
        var replaced = false
        var output = lines(text).map { line in
            guard iniKey(line) == "gentoo_mirrors" else { return line }
            replaced = true
            return assignment
        }
        if !replaced {
            if output.last == "" {
                output.insert(assignment, at: output.count - 1)
            } else {
                output.append(assignment)
            }
        }
        return output.joined(separator: "\n")
    }

    private static func iniKey(_ line: String) -> String? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("#"), !key.hasPrefix(";") else { return nil }
        return key.lowercased()
    }
}
