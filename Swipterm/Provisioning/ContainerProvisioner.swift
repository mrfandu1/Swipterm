import Foundation
import SwiptermKit

nonisolated enum ContainerProvisioner {
    struct Request: Sendable {
        let hostname: String
        let user: String
        let password: String?
        let mirrorID: String?
        let software: ContainerSoftware
    }

    private static let nixPath = [
        "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos",
        "nixos-config=/etc/nixos/configuration.nix",
        "/nix/var/nix/profiles/per-user/root/channels",
    ].joined(separator: ":")

    private static let officialNixCache = "https://cache.nixos.org/"

    static func detectRelease(on runtime: LinuxRuntime) async -> OSRelease? {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            if let data = try? await runtime.fileSystem.contents(of: path), let text = String(data: data, encoding: .utf8) {
                return OSRelease(text)
            }
        }
        return nil
    }

    static func start(
        on runtime: LinuxRuntime,
        terminal: LinuxTerminal,
        request: Request,
        release: OSRelease?,
        log: @escaping @Sendable (String) async -> Void
    ) async throws -> LinuxProcess {
        let distribution = release?.distribution
        let software = request.software
        let developerTools = software.installedDeveloperTools
        var environment = [
            "PATH": "/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "C.UTF-8",
            "DEBIAN_FRONTEND": "noninteractive",
            "SWIPTERM_DISTRIBUTION": distribution?.rawValue ?? "",
            "SWIPTERM_VERSION_ID": release?.versionID ?? "",
            "SWIPTERM_USER": request.user,
            "SWIPTERM_HOSTNAME": request.hostname,
            "SWIPTERM_TOOLS": DeveloperTool.allCases.filter(developerTools.contains).map(\.rawValue).joined(separator: " "),
            "SWIPTERM_AGENTS": CodingAgent.allCases.filter(software.agents.contains).map(\.rawValue).joined(separator: " "),
        ]
        if let password = request.password, !password.isEmpty {
            environment["SWIPTERM_PASSWORD"] = password
        }
        if let shell = software.shell {
            environment["SWIPTERM_SHELL"] = shell.rawValue
        }
        if let ssh = software.ssh {
            environment["SWIPTERM_SSH_PORT"] = String(ssh.port)
            environment["SWIPTERM_SSH_PASSWORD_AUTHENTICATION"] = ssh.authentication.allowsPassword ? "yes" : "no"
            environment["SWIPTERM_SSH_PUBKEY_AUTHENTICATION"] = ssh.authentication.allowsPublicKey ? "yes" : "no"
            if !ssh.authorizedKeys.isEmpty {
                environment["SWIPTERM_SSH_AUTHORIZED_KEYS"] = ssh.authorizedKeys
            }
        }
        let registries = software.registries
        if !registries.isEmpty || distribution != nil {
            await log(step("Mirrors"))
        }
        if !registries.isEmpty {
            let usesChinaMirrors = if let mirror = DistributionMirror.all.first(where: { $0.id == request.mirrorID }) {
                mirror.region == .cn
            } else {
                await DistributionMirrorRouter.regionDetector.region() == .cn
            }
            for registry in registries {
                let mirror = RegistryMirror.resolve(registry, id: software.registryMirrors[registry], usesChinaMirrors: usesChinaMirrors)
                await log("    \(registry.displayName): \(mirror.name) (\(mirror.url))\r\n")
                guard mirror.region != .global else { continue }
                switch registry {
                case .npm:
                    environment["SWIPTERM_NPM_REGISTRY"] = mirror.url
                    environment["SWIPTERM_NODE_DIST"] = mirror.distributionURL
                case .go:
                    environment["SWIPTERM_GOPROXY"] = mirror.url
                    environment["SWIPTERM_GO_DIST"] = mirror.distributionURL
                case .pypi:
                    environment["SWIPTERM_PYPI_INDEX"] = mirror.url
                case .crates:
                    environment["SWIPTERM_CARGO_INDEX"] = mirror.url
                    environment["SWIPTERM_RUSTUP_SERVER"] = mirror.distributionURL
                }
            }
        }

        if let distribution, let release {
            let mirror = try await PackageMirrorResolver.resolve(for: distribution, release: release, mirrorID: request.mirrorID)
            if let mirror {
                await log("    \(distribution.displayName): \(mirror.name) (\(mirror.root.url))\r\n")
            }
            let configurator = PackageRepositoryConfigurator(fileSystem: runtime.fileSystem, distribution: distribution, release: release)
            for path in try await configurator.apply(mirror) {
                await log("    \(path)\r\n")
            }
            let mirrorHost = mirror.flatMap { URL(string: $0.root.url)?.host() }
            if distribution == .nixos {
                var substituters: [String]?
                if let root = mirror?.root, root.url != DistributionMirror.official.packages[.nixos]?.url {
                    substituters = [root.url, officialNixCache]
                }
                let connectionLimit = mirrorHost?.hasSuffix(".edu.cn") == true ? 5 : nil
                let module = nixOSSwiptermModule(
                    hostname: request.hostname,
                    user: request.user,
                    substituters: substituters,
                    connectionLimit: connectionLimit,
                    stateVersion: release.versionID,
                    software: software
                )
                try await runtime.fileSystem.writeFile(
                    "/etc/nixos/swipterm.nix",
                    contents: Data(module.utf8),
                    permissions: 0o644
                )
                await log("    /etc/nixos/swipterm.nix\r\n")
                try await runtime.fileSystem.writeFile(
                    "/etc/nixos/configuration.nix",
                    contents: Data(Self.nixOSConfiguration.utf8),
                    permissions: 0o644
                )
                await log("    /etc/nixos/configuration.nix\r\n")
                environment["NIX_PATH"] = nixPath
                if let substituters {
                    environment["SWIPTERM_NIX_SUBSTITUTERS"] = substituters.joined(separator: " ")
                }
                if let connectionLimit {
                    environment["SWIPTERM_NIX_CONNECTIONS"] = String(connectionLimit)
                }
            }
        }

        return try await runtime.spawn(LinuxProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", setupScript, "swipterm-setup"],
            environment: environment,
            workingDirectory: "/",
            standardInput: .null,
            standardOutput: .terminal(terminal),
            standardError: .terminal(terminal)
        ))
    }

    private static func step(_ message: String) -> String {
        "\u{1B}[1m==> \(message)\u{1B}[0m\r\n"
    }

    private static let nixOSConfiguration = """
    { config, pkgs, ... }:

    {
      imports = [ ./swipterm.nix ];
    }

    """

    private static func nixOSSwiptermModule(
        hostname: String,
        user: String,
        substituters: [String]?,
        connectionLimit: Int?,
        stateVersion: String?,
        software: ContainerSoftware
    ) -> String {
        func literal(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "${", with: "\\${")
            return "\"\(escaped)\""
        }
        func list(_ values: [String]) -> String {
            "[ \(values.map(literal).joined(separator: " ")) ]"
        }
        var lines = [
            "{ config, lib, pkgs, ... }:",
            "",
            "{",
            "  imports = [ <nixpkgs/nixos/modules/virtualisation/lxc-container.nix> ];",
            "",
            "  boot.kernel.enable = lib.mkForce true;",
            "",
            "  networking.hostName = \(literal(hostname));",
            "",
            "  nix.settings.experimental-features = \(list(["nix-command", "flakes"]));",
            "  nix.settings.trusted-users = \(list(["root", "@wheel"]));",
        ]
        if let substituters {
            lines.append("  nix.settings.substituters = \(list(substituters));")
        }
        if let connectionLimit {
            lines.append("  nix.settings.http-connections = \(connectionLimit);")
            lines.append("  nix.settings.max-substitution-jobs = \(connectionLimit);")
        }

        var userAttributes: [String] = []
        switch software.shell {
        case .zsh:
            lines += ["", "  programs.zsh.enable = true;"]
            userAttributes.append("shell = pkgs.zsh;")
        case .fish:
            lines += ["", "  programs.fish.enable = true;"]
            userAttributes.append("shell = pkgs.fish;")
        case .nushell:
            lines += ["", "  environment.shells = [ pkgs.nushell ];"]
            userAttributes.append("shell = pkgs.nushell;")
        case .ash, .bash, nil:
            break
        }

        if let ssh = software.ssh {
            var settings = [
                "PasswordAuthentication = \(ssh.authentication.allowsPassword);",
                "KbdInteractiveAuthentication = \(ssh.authentication.allowsPassword);",
                "PubkeyAuthentication = \(ssh.authentication.allowsPublicKey);",
            ]
            if user == "root" {
                settings.append("PermitRootLogin = \(literal(ssh.authentication.allowsPassword ? "yes" : "prohibit-password"));")
            }
            lines += ["", "  services.openssh = {", "    enable = true;", "    ports = [ \(ssh.port) ];", "    settings = {"]
            lines += settings.map { "      \($0)" }
            lines += ["    };", "  };"]
            let keys = ssh.authorizedKeys
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if ssh.authentication.allowsPublicKey, !keys.isEmpty {
                userAttributes.append("openssh.authorizedKeys.keys = \(list(keys));")
            }
        }

        let developerTools = software.installedDeveloperTools
        let packages = DeveloperTool.allCases.filter(developerTools.contains).flatMap { tool -> [String] in
            switch tool {
            case .buildEssentials: ["gcc", "gnumake"]
            case .git: ["git"]
            case .gnupg: ["gnupg"]
            case .node: ["nodejs_24"]
            case .npm: []
            case .pnpm: ["pnpm"]
            case .bun: ["bun"]
            case .go: ["go"]
            case .python: ["(python3.withPackages (ps: [ ps.pip ]))"]
            case .rust: ["rustc", "cargo"]
            }
        }
        if !packages.isEmpty {
            lines += ["", "  environment.systemPackages = with pkgs; [ \(packages.joined(separator: " ")) ];"]
        }
        if !software.agents.isEmpty {
            lines += ["", "  programs.nix-ld.enable = true;"]
        }
        var extraInit = ["export PATH=\"$PATH:/run/host-bin\""]
        if !developerTools.isEmpty || !software.agents.isEmpty {
            lines += ["", "  environment.localBinInPath = true;"]
            extraInit = [
                "export PNPM_HOME=\"$HOME/.local/share/pnpm\"",
                "export PATH=\"$HOME/.cargo/bin:$HOME/.bun/bin:$PNPM_HOME:$PNPM_HOME/bin:$HOME/go/bin:$PATH:/run/host-bin\"",
            ]
        }
        lines += ["", "  environment.extraInit = ''"] + extraInit.map { "    \($0)" } + ["  '';"]

        if user != "root" {
            lines += [
                "",
                "  users.users.\(literal(user)) = {",
                "    isNormalUser = true;",
                "    extraGroups = \(list(["wheel"]));",
            ]
            lines += userAttributes.map { "    \($0)" }
            lines += [
                "  };",
                "",
                "  security.sudo.extraRules = [",
                "    {",
                "      users = \(list([user]));",
                "      commands = [",
                "        { command = \"ALL\"; options = \(list(["NOPASSWD"])); }",
                "      ];",
                "    }",
                "  ];",
            ]
        } else if !userAttributes.isEmpty {
            lines += ["", "  users.users.root = {"]
            lines += userAttributes.map { "    \($0)" }
            lines.append("  };")
        }
        if let stateVersion, stateVersion.wholeMatch(of: /[0-9]+\.[0-9]+/) != nil {
            lines += ["", "  system.stateVersion = \(literal(stateVersion));"]
        }
        lines += ["}", ""]
        return lines.joined(separator: "\n")
    }

    private static let setupScript = #"""
    set -eu
    umask 022

    user=${SWIPTERM_USER:-root}
    [ -d /tmp ] || mkdir -m 1777 /tmp
    work=$(mktemp -d /tmp/swipterm.XXXXXX)
    trap 'rm -rf "$work"' EXIT

    step() {
        printf '\n\033[1m==> %s\033[0m\n' "$*"
    }

    fail() {
        printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
        exit 1
    }

    warn() {
        printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
    }

    have() {
        command -v "$1" >/dev/null 2>&1
    }

    set_option() {
        mkdir -p "${1%/*}"
        if [ -f "$1" ] && grep -q "^$2=" "$1"; then
            sed -i "s/^$2=.*/$2=$3/" "$1"
        else
            printf '%s=%s\n' "$2" "$3" >> "$1"
        fi
    }

    mask() {
        for path in "$@"; do
            mkdir -p "${path%/*}"
            ln -sf /dev/null "$path"
        done
    }

    in_group() {
        id -nG "$1" | tr ' ' '\n' | grep -qx "$2"
    }

    want_tool() {
        case "$tools" in
        *" $1 "*) return 0 ;;
        esac
        return 1
    }

    want_agent() {
        case "$agents" in
        *" $1 "*) return 0 ;;
        esac
        return 1
    }

    version_at_least() {
        version=${SWIPTERM_VERSION_ID%%_*}
        version_major=${version%%.*}
        version_minor=${version#"$version_major"}
        version_minor=${version_minor#.}
        version_minor=${version_minor%%.*}
        [ "${version_major:-0}" -gt "$1" ] ||
            { [ "${version_major:-0}" -eq "$1" ] && [ "${version_minor:-0}" -ge "${2:-0}" ]; }
    }

    has_recent_packages() {
        case "$SWIPTERM_DISTRIBUTION" in
        alma | oracle | rocky) version_at_least 9 ;;
        debian) [ -z "$SWIPTERM_VERSION_ID" ] || version_at_least 14 ;;
        ubuntu) version_at_least 26 ;;
        devuan | openEuler) return 1 ;;
        *) return 0 ;;
        esac
    }

    go_from_packages() {
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            version_at_least 3 24
        else
            has_recent_packages
        fi
    }

    fetch() {
        curl -fsSL --retry 3 "$1"
    }

    download() {
        curl -fL --retry 3 --progress-bar -o "$2" "$1"
    }

    verify() {
        if [ "$("${1}sum" "$3" | cut -d ' ' -f 1)" != "$2" ]; then
            fail "The $1 checksum of $4 does not match."
        fi
    }

    json_value() {
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
    }

    npm_tarball() {
        fetch "$npm_registry/$1/$2" > "$work/package.json"
        tarball=$(json_value tarball < "$work/package.json")
        case "$tarball" in
        /*) tarball=$npm_registry$tarball ;;
        esac
        download "$tarball" "$3"
        integrity=$(json_value integrity < "$work/package.json")
        verify sha512 "$(printf '%s' "${integrity#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')" "$3" "$1"
    }

    as_user() {
        su -l -s /bin/sh "$user" -c "[ -r /etc/profile.d/swipterm.sh ] && . /etc/profile.d/swipterm.sh; $1"
    }

    prepare_arch() {
        if [ -f /etc/locale.gen ] && have locale-gen; then
            step "Locale"
            if ! grep -q '^en_US\.UTF-8 UTF-8' /etc/locale.gen; then
                if grep -q '^#[[:space:]]*en_US\.UTF-8 UTF-8' /etc/locale.gen; then
                    sed -i 's/^#[[:space:]]*\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
                else
                    printf 'en_US.UTF-8 UTF-8\n' >> /etc/locale.gen
                fi
            fi
            locale-gen
        fi
        step "Keyring"
        pacman-key --init
        if [ -f /usr/share/pacman/keyrings/archlinuxarm.gpg ]; then
            pacman-key --populate archlinuxarm
        else
            pacman-key --populate
        fi
    }

    prepare_dnf() {
        grep -qs '^\[main\]' /etc/dnf/dnf.conf || printf '[main]\n' >> /etc/dnf/dnf.conf
        set_option /etc/dnf/dnf.conf max_parallel_downloads 5
    }

    prepare_alpine() {
        if ! have sudo; then
            step "sudo"
            apk add --no-cache sudo
        fi
    }

    gentoo_sync() {
        if [ ! -d /var/db/repos/gentoo/profiles ]; then
            step "Portage"
            emerge-webrsync
        fi
    }

    prepare_gentoo() {
        if ! have sudo; then
            gentoo_sync
            step "sudo"
            emerge --getbinpkg --usepkg --noreplace app-admin/sudo
        fi
    }

    has_kernel() {
        running=$(uname -r)
        for modules in /lib/modules/* /usr/lib/modules/*; do
            kver=${modules##*/}
            if [ "$kver" = "$running" ] || [ ! -f "$modules/modules.dep" ]; then
                continue
            fi
            if [ -s "$modules/vmlinuz" ] || [ -s "$modules/Image" ] ||
                [ -s "/boot/vmlinuz-$kver" ] || [ -s "/boot/vmlinux-$kver" ] ||
                [ -s "/boot/Image-$kver" ] || [ -s "/boot/kernel-$kver" ] ||
                [ -s /boot/vmlinuz-virt ] || [ -s /boot/Image.gz ] || [ -s /boot/Image ]; then
                return 0
            fi
        done
        return 1
    }

    install_kernel() {
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            set_option /etc/initramfs-tools/update-initramfs.conf update_initramfs no
            INITRD=No dpkg --force-confold --configure -a
            ;;
        esac
        has_kernel && return 0
        case "$SWIPTERM_DISTRIBUTION:$SWIPTERM_VERSION_ID" in
        alma:8 | alma:8.* | rocky:8 | rocky:8.*)
            warn "Version 8 of this distribution only ships 64K-page kernels; using the built-in kernel."
            return 0
            ;;
        esac
        step "Kernel"
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            apt-get update
            case "$SWIPTERM_DISTRIBUTION" in
            ubuntu)
                INITRD=No apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold \
                    linux-image-virtual
                ;;
            kali)
                INITRD=No apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold \
                    linux-image-cloud-arm64 initramfs-tools ||
                    INITRD=No apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold \
                        linux-image-arm64 initramfs-tools
                ;;
            *)
                INITRD=No apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold \
                    linux-image-cloud-arm64 initramfs-tools
                ;;
            esac
            ;;
        alpine)
            set_option /etc/mkinitfs/mkinitfs.conf disable_trigger yes
            apk add --no-cache linux-virt
            ;;
        arch)
            if [ -e /var/lib/pacman/db.lck ] && ! pgrep -x pacman >/dev/null 2>&1; then
                rm -f /var/lib/pacman/db.lck
            fi
            mask /etc/pacman.d/hooks/90-mkinitcpio-install.hook
            pacman -Syu --noconfirm --needed --disable-download-timeout linux-aarch64
            ;;
        alma | centos | fedora | openEuler | oracle | rocky)
            mask /etc/kernel/install.d/50-dracut.install /etc/kernel/install.d/20-grub.install
            case "$SWIPTERM_DISTRIBUTION:$SWIPTERM_VERSION_ID" in
            openEuler:*)
                mkdir -p /etc/sysconfig
                if ! grep -qs '^dracut()' /etc/sysconfig/kernel; then
                    printf 'dracut() { :; }\n' >> /etc/sysconfig/kernel
                fi
                dnf -y --setopt=install_weak_deps=False install kernel
                ;;
            oracle:8 | oracle:8.*)
                uek=$(dnf -q repoquery --latest-limit=1 kernel-uek-core)
                if [ -z "$uek" ]; then
                    warn "No 4K-page UEK kernel is available; using the built-in kernel."
                    return 0
                fi
                dnf -y --setopt=install_weak_deps=False install kernel-uek-core
                ;;
            oracle:*)
                dnf -y --setopt=install_weak_deps=False install kernel-core kernel-modules-core ||
                    dnf -y --setopt=install_weak_deps=False install kernel-uek-core
                ;;
            *)
                dnf -y --setopt=install_weak_deps=False install kernel-core kernel-modules-core
                ;;
            esac
            ;;
        openSUSE)
            mask /etc/kernel/install.d/50-dracut.install
            DRACUT=/usr/bin/true zypper --non-interactive install --no-recommends kernel-kvmsmall ||
                DRACUT=/usr/bin/true zypper --non-interactive install --no-recommends kernel-default-base
            ;;
        void)
            xbps-install -Suy xbps
            package=$(xbps-query -Rs --regex '^linux6\.[0-9]+-[0-9]' |
                sed -n 's/^\[.\] \(linux6\.[0-9]*\)-.*/\1/p' | sort -t . -k 2 -n | tail -n 1)
            if [ -n "$package" ]; then
                xbps-install -Sy "$package"
            else
                xbps-install -Sy linux6.12 || xbps-install -Sy linux
            fi
            ;;
        gentoo)
            gentoo_sync
            if ! emerge --ask=n --autounmask=n --getbinpkg=y --usepkgonly virtual/dist-kernel &&
                ! emerge --ask=n --autounmask=n --getbinpkg=y --usepkgonly sys-kernel/gentoo-kernel-bin; then
                warn "No prebuilt Gentoo kernel binary package is available; using the built-in kernel."
            fi
            ;;
        esac
    }

    add() {
        packages="$packages $*"
    }

    downloads_upstream() {
        if want_agent codex || want_agent antigravity || want_tool rust; then
            return 0
        fi
        if want_tool go && ! go_from_packages; then
            return 0
        fi
        if want_tool node && ! has_recent_packages; then
            return 0
        fi
        [ "$SWIPTERM_DISTRIBUTION" != arch ] && { want_tool pnpm || want_tool bun; }
    }

    collect_packages() {
        packages=
        case "${SWIPTERM_SHELL:-}:$SWIPTERM_DISTRIBUTION" in
        bash:*) have bash || add bash ;;
        zsh:gentoo) have zsh || add app-shells/zsh ;;
        zsh:*) have zsh || add zsh ;;
        fish:gentoo) have fish || add app-shells/fish ;;
        fish:void) have fish || add fish-shell ;;
        fish:*) have fish || add fish ;;
        nushell:*) have nu || add nushell ;;
        esac
        if [ -n "${SWIPTERM_SSH_PORT:-}" ] && ! have sshd; then
            case "$SWIPTERM_DISTRIBUTION" in
            arch | void) add openssh ;;
            gentoo) add net-misc/openssh ;;
            *) add openssh-server ;;
            esac
        fi
        if want_tool build-essentials; then
            case "$SWIPTERM_DISTRIBUTION" in
            alpine) add build-base ;;
            arch | void) add base-devel ;;
            debian | devuan | kali | ubuntu) add build-essential ;;
            gentoo) ;;
            *) add gcc gcc-c++ make ;;
            esac
        fi
        if want_tool git && ! have git; then
            case "$SWIPTERM_DISTRIBUTION" in
            gentoo) add dev-vcs/git ;;
            *) add git ;;
            esac
        fi
        if want_tool gnupg && ! have gpg; then
            case "$SWIPTERM_DISTRIBUTION" in
            alma | centos | fedora | openEuler | oracle | rocky) add gnupg2 ;;
            openSUSE) add gpg2 ;;
            gentoo) add app-crypt/gnupg ;;
            *) add gnupg ;;
            esac
        fi
        if want_tool python; then
            case "$SWIPTERM_DISTRIBUTION" in
            alpine) add python3 py3-pip ;;
            arch) add python python-pip ;;
            debian | devuan | kali | ubuntu) add python3 python3-pip python3-venv ;;
            gentoo) add dev-python/pip ;;
            *) add python3 python3-pip ;;
            esac
        fi
        if want_tool go && go_from_packages; then
            case "$SWIPTERM_DISTRIBUTION" in
            alma | centos | fedora | oracle | rocky) add golang ;;
            debian | kali | ubuntu) add golang-go ;;
            gentoo) add dev-lang/go ;;
            *) add go ;;
            esac
        fi
        if want_tool node; then
            if has_recent_packages; then
                case "$SWIPTERM_DISTRIBUTION" in
                gentoo) add net-libs/nodejs ;;
                openSUSE) ;;
                *) add nodejs ;;
                esac
                if want_tool npm; then
                    case "$SWIPTERM_DISTRIBUTION" in
                    gentoo | openSUSE | void) ;;
                    *) add npm ;;
                    esac
                fi
            else
                case "$SWIPTERM_DISTRIBUTION" in
                alma | centos | fedora | openEuler | oracle | rocky) add libatomic ;;
                debian | devuan | kali | ubuntu) add libatomic1 ;;
                esac
            fi
        fi
        if [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            if want_tool pnpm; then
                add pnpm
            fi
            if want_tool bun; then
                add bun
            fi
        fi
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            if want_tool pnpm || want_tool bun || want_agent claude-code; then
                add libgcc libstdc++
            fi
            if want_agent codex; then
                add ripgrep
            fi
        fi
        if downloads_upstream; then
            if [ "$SWIPTERM_DISTRIBUTION" = gentoo ]; then
                have curl || add net-misc/curl
            else
                have curl || add curl
                have tar || add tar
                add ca-certificates
            fi
        fi
    }

    install_packages() {
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            apt-get update
            apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "$@"
            ;;
        alpine)
            apk add --no-cache "$@"
            ;;
        arch)
            pacman -Syu --noconfirm --needed --disable-download-timeout "$@"
            ;;
        alma | centos | fedora | openEuler | oracle | rocky)
            if [ "$SWIPTERM_DISTRIBUTION" = oracle ]; then
                dnf -y install "oraclelinux-release-el${SWIPTERM_VERSION_ID%%.*}" || true
            fi
            if want_tool node; then
                case "$SWIPTERM_DISTRIBUTION:${SWIPTERM_VERSION_ID%%.*}" in
                alma:9 | centos:9 | oracle:9 | rocky:9) dnf -y module enable nodejs:24 || dnf -y module enable nodejs:22 ;;
                esac
            fi
            dnf -y --setopt=install_weak_deps=False install "$@"
            ;;
        openSUSE)
            zypper --non-interactive install --no-recommends "$@"
            ;;
        void)
            xbps-install -Suy xbps
            xbps-install -Sy "$@"
            ;;
        gentoo)
            gentoo_sync
            emerge --ask=n --getbinpkg --usepkg --noreplace "$@"
            ;;
        esac
    }

    install_opensuse_node() {
        step "Node.js"
        opensuse_node_pkgs=nodejs24
        opensuse_fallback_pkgs=nodejs-default
        if want_tool npm; then
            opensuse_node_pkgs="$opensuse_node_pkgs npm24"
            opensuse_fallback_pkgs="$opensuse_fallback_pkgs npm-default"
        fi
        zypper --non-interactive install --no-recommends $opensuse_node_pkgs ||
            zypper --non-interactive install --no-recommends $opensuse_fallback_pkgs
        for tool in node npm npx; do
            if ! have "$tool" && [ -x "/usr/bin/${tool}24" ]; then
                ln -s "${tool}24" "/usr/bin/$tool"
            fi
        done
    }

    install_go() {
        if ! want_tool go || go_from_packages; then
            return 0
        fi
        step "Go"
        base=${SWIPTERM_GO_DIST:-https://go.dev/dl}
        fetch "$base/?mode=json" > "$work/go.json"
        archive=$(sed -n 's/.*"filename"[[:space:]]*:[[:space:]]*"\(go[^"]*\.linux-arm64\.tar\.gz\)".*/\1/p' "$work/go.json" | head -n 1)
        sha256=$(sed -n "/\"$archive\"/,/\"sha256\"/s/.*\"sha256\"[[:space:]]*:[[:space:]]*\"\([0-9a-f]*\)\".*/\1/p" "$work/go.json" | head -n 1)
        download "$base/$archive" "$work/$archive"
        verify sha256 "$sha256" "$work/$archive" "$archive"
        rm -rf /usr/local/go
        tar -xzf "$work/$archive" -C /usr/local
    }

    install_node() {
        if ! want_tool node || has_recent_packages; then
            return 0
        fi
        step "Node.js"
        base=${SWIPTERM_NODE_DIST:-https://nodejs.org/dist}/latest-v24.x
        fetch "$base/SHASUMS256.txt" > "$work/SHASUMS256.txt"
        checksum=$(grep ' node-v[0-9.]*-linux-arm64\.tar\.gz$' "$work/SHASUMS256.txt" | head -n 1)
        archive=${checksum##* }
        download "$base/$archive" "$work/$archive"
        verify sha256 "${checksum%% *}" "$work/$archive" "$archive"
        tar -xzf "$work/$archive" -C "$work"
        node=$work/${archive%.tar.gz}
        if ! want_tool npm; then
            rm -rf "$node/bin/npm" "$node/bin/npx" "$node/bin/corepack" "$node/lib/node_modules"
        fi
        cp -R "$node/bin" "$node/include" "$node/lib" "$node/share" /usr/local/
    }

    install_pnpm() {
        if ! want_tool pnpm || [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            return 0
        fi
        step "pnpm"
        fetch "$npm_registry/@pnpm/exe/latest" > "$work/pnpm.json"
        version=$(json_value version < "$work/pnpm.json")
        [ -n "$version" ] || fail "Could not resolve the latest version of pnpm."
        npm_tarball "@pnpm/exe.linux-arm64$musl" "$version" "$work/pnpm.tgz"
        mkdir "$work/pnpm"
        tar -xzf "$work/pnpm.tgz" -C "$work/pnpm"
        install -m 0755 "$work/pnpm/package/pnpm" /usr/local/bin/pnpm
        for name in pn pnpx pnx; do
            ln -sf pnpm "/usr/local/bin/$name"
        done
    }

    install_bun() {
        if ! want_tool bun || [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            return 0
        fi
        step "Bun"
        fetch "$npm_registry/bun/latest" > "$work/bun.json"
        version=$(json_value version < "$work/bun.json")
        [ -n "$version" ] || fail "Could not resolve the latest version of Bun."
        npm_tarball "@oven/bun-linux-aarch64$musl" "$version" "$work/bun.tgz"
        mkdir "$work/bun"
        tar -xzf "$work/bun.tgz" -C "$work/bun"
        install -m 0755 "$work/bun/package/bin/bun" /usr/local/bin/bun
        ln -sf bun /usr/local/bin/bunx
    }

    install_software() {
        collect_packages
        if [ -n "$packages" ]; then
            step "Packages"
            install_packages $packages
        fi
        if [ "$SWIPTERM_DISTRIBUTION" = openSUSE ] && want_tool node; then
            install_opensuse_node
        fi
        install_go
        install_node
        install_pnpm
        install_bun
    }

    remove_template_user() {
        template=$1
        [ "$template" != "$user" ] || return 0
        id "$template" >/dev/null 2>&1 || return 0
        userdel -r "$template" || true
        if id "$template" >/dev/null 2>&1; then
            fail "Could not remove the template user $template."
        fi
    }

    admin_group() {
        for group in wheel sudo; do
            if grep -q "^$group:" /etc/group; then
                printf '%s\n' "$group"
                return
            fi
        done
        if have groupadd; then
            groupadd --system wheel
        else
            addgroup -S wheel
        fi
        printf 'wheel\n'
    }

    shell_path() {
        name=$SWIPTERM_SHELL
        if [ "$name" = nushell ]; then
            name=nu
        fi
        for directory in /usr/bin /bin; do
            if [ -x "$directory/$name" ]; then
                printf '%s\n' "$directory/$name"
                return
            fi
        done
        fail "$name is not installed."
    }

    login_shell() {
        if [ -n "${SWIPTERM_SHELL:-}" ]; then
            shell_path
            return
        fi
        for shell in /bin/bash /bin/ash /bin/sh; do
            if [ -x "$shell" ]; then
                printf '%s\n' "$shell"
                return
            fi
        done
        printf '/bin/sh\n'
    }

    create_user() {
        group=$(admin_group)
        shell=$(login_shell)
        if id "$user" >/dev/null 2>&1; then
            uid=$(id -u "$user")
            if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
                fail "$user is a system account. Choose another username."
            fi
        else
            if have useradd; then
                useradd --create-home --shell "$shell" "$user"
            else
                adduser -D -s "$shell" -h "/home/$user" "$user"
            fi
        fi
        if ! in_group "$user" "$group"; then
            if have usermod; then
                usermod -a -G "$group" "$user"
            else
                addgroup "$user" "$group"
            fi
        fi
        if [ -n "${SWIPTERM_PASSWORD:-}" ]; then
            printf '%s:%s\n' "$user" "$SWIPTERM_PASSWORD" | chpasswd
        elif have usermod; then
            usermod -p '*' "$user"
        else
            printf '%s:*\n' "$user" | chpasswd -e
        fi
    }

    configure_sudo() {
        have sudo || return 0
        sudoers=/etc/sudoers
        if [ ! -e "$sudoers" ] && [ -e /usr/etc/sudoers ]; then
            sudoers=/usr/etc/sudoers
        fi
        if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d/?[[:space:]]*$' "$sudoers" 2>/dev/null; then
            if [ "$sudoers" != /etc/sudoers ]; then
                cp "$sudoers" /etc/sudoers
            fi
            printf '\n#includedir /etc/sudoers.d\n' >> /etc/sudoers
            chmod 0440 /etc/sudoers
        fi
        mkdir -p /etc/sudoers.d
        chown 0:0 /etc/sudoers.d
        chmod 0755 /etc/sudoers.d
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > /etc/sudoers.d/swipterm
        chown 0:0 /etc/sudoers.d/swipterm
        chmod 0440 /etc/sudoers.d/swipterm
        if have visudo; then
            if [ -e /etc/sudoers ]; then
                valid() { visudo -cf /etc/sudoers; }
            else
                valid() { visudo -cf /etc/sudoers.d/swipterm; }
            fi
            if ! valid; then
                rm -f /etc/sudoers.d/swipterm
                fail "sudo rejected the generated configuration."
            fi
        fi
    }

    configure_doas() {
        have doas || return 0
        mkdir -p /etc/doas.d
        chown 0:0 /etc/doas.d
        chmod 0755 /etc/doas.d
        printf 'permit nopass %s\n' "$user" > /etc/doas.d/swipterm.conf
        chown 0:0 /etc/doas.d/swipterm.conf
        chmod 0400 /etc/doas.d/swipterm.conf
        if ! doas -C /etc/doas.d/swipterm.conf; then
            rm -f /etc/doas.d/swipterm.conf
            fail "doas rejected the generated configuration."
        fi
    }

    load_user() {
        user_home=$(getent passwd "$user" | cut -d : -f 6)
        user_group=$(id -gn "$user")
    }

    create_shell_config() {
        case "${SWIPTERM_SHELL:-}" in
        zsh)
            if [ ! -e "$user_home/.zshrc" ]; then
                touch "$user_home/.zshrc"
                chown "$user:$user_group" "$user_home/.zshrc"
            fi
            ;;
        nushell)
            as_user 'mkdir -p "$HOME/.config/nushell" && touch "$HOME/.config/nushell/env.nu" "$HOME/.config/nushell/config.nu"'
            nu_config=$user_home/.config/nushell/config.nu
            if [ -n "${SWIPTERM_TOOLS:-}${SWIPTERM_AGENTS:-}" ] && [ ! -s "$nu_config" ]; then
                cat > "$nu_config" <<'EOF'
    $env.PNPM_HOME = ($env.HOME | path join ".local" "share" "pnpm")
    $env.PATH = ($env.PATH | split row (char esep) | prepend [
        ($env.HOME | path join ".local" "bin")
        ($env.HOME | path join ".bun" "bin")
        ($env.HOME | path join ".cargo" "bin")
        $env.PNPM_HOME
        ($env.PNPM_HOME | path join "bin")
        ($env.HOME | path join "go" "bin")
        "/usr/local/go/bin"
    ] | uniq)
    EOF
                if [ -n "${SWIPTERM_RUSTUP_SERVER:-}" ]; then
                    printf '$env.RUSTUP_DIST_SERVER = "%s"\n$env.RUSTUP_UPDATE_ROOT = "%s/rustup"\n' \
                        "$SWIPTERM_RUSTUP_SERVER" "$SWIPTERM_RUSTUP_SERVER" >> "$nu_config"
                fi
            fi
            if ! grep -qF /run/host-bin "$nu_config"; then
                printf '%s\n' '$env.PATH = ($env.PATH | split row (char esep) | append "/run/host-bin" | uniq)' >> "$nu_config"
            fi
            ;;
        esac
    }

    configure_login_shell() {
        [ -n "${SWIPTERM_SHELL:-}" ] || return 0
        shell=$(shell_path)
        if [ -f /etc/shells ] && ! grep -qx "$shell" /etc/shells; then
            printf '%s\n' "$shell" >> /etc/shells
        fi
        if [ "$(getent passwd "$user" | cut -d : -f 7)" != "$shell" ]; then
            if have usermod; then
                usermod -s "$shell" "$user"
            else
                sed -i "s|^\($user:\([^:]*:\)\{5\}\)[^:]*\$|\1$shell|" /etc/passwd
            fi
        fi
        create_shell_config
    }

    configure_ssh() {
        [ -n "${SWIPTERM_SSH_PORT:-}" ] || return 0
        step "SSH"
        mkdir -p /run/sshd
        ssh-keygen -A
        sshd_bin=$(command -v sshd)
        password=${SWIPTERM_SSH_PASSWORD_AUTHENTICATION:-yes}
        pubkey=${SWIPTERM_SSH_PUBKEY_AUTHENTICATION:-no}
        {
            printf 'Port %s\n' "$SWIPTERM_SSH_PORT"
            printf 'PasswordAuthentication %s\n' "$password"
            printf 'KbdInteractiveAuthentication %s\n' "$password"
            printf 'ChallengeResponseAuthentication %s\n' "$password"
            printf 'PubkeyAuthentication %s\n' "$pubkey"
            if [ "$user" = root ] && [ "$password" = yes ]; then
                printf 'PermitRootLogin yes\n'
            elif [ "$user" = root ]; then
                printf 'PermitRootLogin prohibit-password\n'
            fi
        } > "$work/sshd_swipterm"
        if [ -f /etc/ssh/sshd_config ] &&
            ! grep -Eq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
            directives='Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication'
            if [ "$user" = root ]; then
                directives="$directives|PermitRootLogin"
            fi
            sed -i -E "s/^[[:space:]]*($directives)[[:space:]=]/#&/" /etc/ssh/sshd_config
            { cat "$work/sshd_swipterm"; printf '\n'; cat /etc/ssh/sshd_config; } > "$work/sshd_config"
            cat "$work/sshd_config" > /etc/ssh/sshd_config
        else
            if [ -f /etc/ssh/sshd_config ]; then
                sed -i -E 's/^[[:space:]]*Port[[:space:]=]/#&/' /etc/ssh/sshd_config
            fi
            mkdir -p /etc/ssh/sshd_config.d
            cat "$work/sshd_swipterm" > /etc/ssh/sshd_config.d/10-swipterm.conf
        fi
        if [ "$pubkey" = yes ] && [ -n "${SWIPTERM_SSH_AUTHORIZED_KEYS:-}" ]; then
            mkdir -p "$user_home/.ssh"
            printf '%s\n' "$SWIPTERM_SSH_AUTHORIZED_KEYS" > "$user_home/.ssh/authorized_keys"
            chmod 0700 "$user_home/.ssh"
            chmod 0600 "$user_home/.ssh/authorized_keys"
            chown -R "$user:$user_group" "$user_home/.ssh"
        fi
        if ! "$sshd_bin" -t; then
            fail "sshd rejected the generated configuration."
        fi
        case "$SWIPTERM_DISTRIBUTION:$SWIPTERM_VERSION_ID" in
        ubuntu:2[0-3].* | debian:* | kali:*)
            if have systemctl; then
                systemctl enable ssh.service
            fi
            ;;
        ubuntu:*)
            if have systemctl; then
                systemctl enable ssh.socket
            fi
            ;;
        devuan:*)
            if have update-rc.d; then
                update-rc.d ssh defaults
            fi
            ;;
        alpine:*)
            if have rc-update; then
                rc-update add sshd default
            fi
            ;;
        void:*)
            if [ -d /etc/sv/sshd ]; then
                mkdir -p /etc/runit/runsvdir/default
                ln -sfn /etc/sv/sshd /etc/runit/runsvdir/default/sshd
            fi
            ;;
        gentoo:*)
            if have rc-update; then
                rc-update add sshd default
            elif have systemctl; then
                systemctl enable sshd.service
            fi
            ;;
        *)
            if have systemctl; then
                systemctl enable sshd.service
            fi
            ;;
        esac
    }

    configure_path() {
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            if [ -e /etc/zsh/zprofile ] || have zsh; then
                line='emulate sh -c '\''for swipterm_profile in /etc/profile.d/*.sh; do [ -r "$swipterm_profile" ] && . "$swipterm_profile"; done; unset swipterm_profile'\'
                mkdir -p /etc/zsh
                if ! grep -qxF "$line" /etc/zsh/zprofile 2>/dev/null; then
                    printf '%s\n' "$line" >> /etc/zsh/zprofile
                fi
            fi
            ;;
        esac
        if [ -z "${SWIPTERM_TOOLS:-}${SWIPTERM_AGENTS:-}" ]; then
            return 0
        fi
        mkdir -p /etc/profile.d /etc/fish/conf.d
        cat > /etc/profile.d/swipterm.sh <<'EOF'
    PNPM_HOME="$HOME/.local/share/pnpm"
    export PNPM_HOME
    for swipterm_path in /usr/local/go/bin "$HOME/go/bin" "$PNPM_HOME/bin" "$PNPM_HOME" "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
        case ":$PATH:" in
        *":$swipterm_path:"*) ;;
        *) PATH="$swipterm_path:$PATH" ;;
        esac
    done
    unset swipterm_path
    export PATH
    EOF
        cat > /etc/fish/conf.d/swipterm.fish <<'EOF'
    set -gx PNPM_HOME $HOME/.local/share/pnpm
    for swipterm_path in /usr/local/go/bin $HOME/go/bin $PNPM_HOME/bin $PNPM_HOME $HOME/.bun/bin $HOME/.cargo/bin $HOME/.local/bin
        contains -- $swipterm_path $PATH
        or set -gx PATH $swipterm_path $PATH
    end
    EOF
        if [ -n "${SWIPTERM_RUSTUP_SERVER:-}" ]; then
            printf 'RUSTUP_DIST_SERVER=%s\nRUSTUP_UPDATE_ROOT=%s/rustup\nexport RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT\n' \
                "$SWIPTERM_RUSTUP_SERVER" "$SWIPTERM_RUSTUP_SERVER" >> /etc/profile.d/swipterm.sh
            printf 'set -gx RUSTUP_DIST_SERVER %s\nset -gx RUSTUP_UPDATE_ROOT %s/rustup\n' \
                "$SWIPTERM_RUSTUP_SERVER" "$SWIPTERM_RUSTUP_SERVER" >> /etc/fish/conf.d/swipterm.fish
        fi
    }

    write_user_config() {
        printf '    ~/%s\n' "$1"
        as_user "mkdir -p \"\$HOME/$(dirname "$1")\" && cat > \"\$HOME/$1\""
    }

    configure_mirrors() {
        if [ -z "${SWIPTERM_NPM_REGISTRY:-}${SWIPTERM_GOPROXY:-}${SWIPTERM_PYPI_INDEX:-}${SWIPTERM_CARGO_INDEX:-}" ]; then
            return 0
        fi
        if [ -n "${SWIPTERM_NPM_REGISTRY:-}" ]; then
            printf 'registry=%s/\n' "$SWIPTERM_NPM_REGISTRY" | write_user_config .npmrc
        fi
        if [ -n "${SWIPTERM_GOPROXY:-}" ]; then
            printf 'GOPROXY=%s,direct\n' "$SWIPTERM_GOPROXY" | write_user_config .config/go/env
        fi
        if [ -n "${SWIPTERM_PYPI_INDEX:-}" ]; then
            printf '[global]\nindex-url = %s\n' "$SWIPTERM_PYPI_INDEX" | write_user_config .config/pip/pip.conf
        fi
        if [ -n "${SWIPTERM_CARGO_INDEX:-}" ]; then
            printf '[source.crates-io]\nreplace-with = "mirror"\n\n[source.mirror]\nregistry = "sparse+%s/"\n' \
                "$SWIPTERM_CARGO_INDEX" | write_user_config .cargo/config.toml
        fi
    }

    install_rust() {
        if ! want_tool rust; then
            return 0
        fi
        step "Rust"
        rustup_server=${SWIPTERM_RUSTUP_SERVER:-https://static.rust-lang.org}
        target=aarch64-unknown-linux-gnu
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            target=aarch64-unknown-linux-musl
        fi
        download "$rustup_server/rustup/dist/$target/rustup-init" "$work/rustup-init"
        verify sha256 "$(fetch "$rustup_server/rustup/dist/$target/rustup-init.sha256" | cut -d ' ' -f 1)" "$work/rustup-init" rustup-init
        rustup_dir=$(mktemp -d /tmp/swipterm-rustup.XXXXXX)
        chown "$user:$user_group" "$rustup_dir"
        install -m 0755 "$work/rustup-init" "$rustup_dir/rustup-init"
        as_user "\"$rustup_dir/rustup-init\" -y --profile minimal --no-modify-path"
        rm -rf "$rustup_dir"
    }

    install_antigravity() {
        if ! want_agent antigravity; then
            return 0
        fi
        step "Antigravity"
        platform=linux_arm64
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            platform=linux_arm64_musl
        fi
        fetch "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$platform.json" > "$work/antigravity.json"
        download "$(json_value url < "$work/antigravity.json")" "$work/antigravity.tar.gz"
        verify sha512 "$(json_value sha512 < "$work/antigravity.json")" "$work/antigravity.tar.gz" "Antigravity CLI"
        mkdir "$work/antigravity"
        tar -xzf "$work/antigravity.tar.gz" -C "$work/antigravity"
        as_user 'mkdir -p "$HOME/.local/bin"'
        install -m 0755 -o "$user" -g "$user_group" "$work/antigravity/antigravity" "$user_home/.local/bin/agy"
        as_user '"$HOME/.local/bin/agy" install' || true
    }

    install_codex() {
        if ! want_agent codex; then
            return 0
        fi
        step "Codex"
        fetch "$npm_registry/@openai/codex/latest" > "$work/codex.json"
        version=$(json_value version < "$work/codex.json")
        [ -n "$version" ] || fail "Could not resolve the latest version of Codex."
        npm_tarball @openai/codex "$version-linux-arm64" "$work/codex.tgz"
        standalone=$user_home/.codex/packages/standalone
        release=$standalone/releases/$version-aarch64-unknown-linux-musl
        as_user "mkdir -p \"$release\" \"\$HOME/.local/bin\" &&
            tar -xzf - -C \"$release\" --strip-components=3 &&
            ln -sfn \"$release\" \"$standalone/current\" &&
            ln -sf \"$standalone/current/bin/codex\" \"\$HOME/.local/bin/codex\"" < "$work/codex.tgz"
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            as_user "ln -sf /usr/bin/rg \"$release/codex-path/rg\""
        fi
        write_user_config .codex/config.toml <<'EOF'
    check_for_update_on_startup = false

    [features]
    daemon_auto_start = false
    EOF
    }

    install_agents() {
        if want_agent claude-code; then
            step "Claude Code"
            if want_tool pnpm; then
                as_user "pnpm add --global --registry=$npm_registry --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code"
            elif want_tool bun; then
                as_user "bun add --global --trust --registry=$npm_registry @anthropic-ai/claude-code"
            else
                as_user "npm install --global --prefix \"\$HOME/.local\" --registry=$npm_registry @anthropic-ai/claude-code"
            fi
        fi
        install_codex
        install_antigravity
    }

    case "$user" in
    root) ;;
    "" | -* | *[!A-Za-z0-9._-]*) fail "Invalid username: $user" ;;
    esac

    if [ -z "$SWIPTERM_DISTRIBUTION" ] &&
        [ -n "${SWIPTERM_SHELL:-}${SWIPTERM_SSH_PORT:-}${SWIPTERM_TOOLS:-}${SWIPTERM_AGENTS:-}" ]; then
        warn "The distribution is not recognized; skipping the selected software."
        SWIPTERM_SHELL='' SWIPTERM_SSH_PORT='' SWIPTERM_TOOLS='' SWIPTERM_AGENTS=''
    fi
    tools=" ${SWIPTERM_TOOLS:-} "
    agents=" ${SWIPTERM_AGENTS:-} "
    musl=
    if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
        musl=-musl
    fi
    npm_registry=${SWIPTERM_NPM_REGISTRY:-https://registry.npmjs.org}

    case "$SWIPTERM_DISTRIBUTION" in
    nixos)
        step "NixOS"
        set -- switch
        if [ -n "${SWIPTERM_NIX_SUBSTITUTERS:-}" ]; then
            set -- "$@" --option substituters "$SWIPTERM_NIX_SUBSTITUTERS"
        fi
        if [ -n "${SWIPTERM_NIX_CONNECTIONS:-}" ]; then
            set -- "$@" --option http-connections "$SWIPTERM_NIX_CONNECTIONS" \
                --option max-substitution-jobs "$SWIPTERM_NIX_CONNECTIONS"
        fi
        nixos-rebuild "$@"
        if [ -n "${SWIPTERM_PASSWORD:-}" ]; then
            printf '%s:%s\n' "$user" "$SWIPTERM_PASSWORD" | chpasswd
        fi
        load_user
        create_shell_config
        configure_mirrors
        install_agents
        step "Done"
        exit 0
        ;;
    arch) prepare_arch ;;
    alpine) prepare_alpine ;;
    alma | centos | fedora | openEuler | oracle | rocky) prepare_dnf ;;
    gentoo) prepare_gentoo ;;
    esac

    if [ -n "$SWIPTERM_DISTRIBUTION" ]; then
        install_kernel
        install_software
    fi

    if [ "$user" != root ]; then
        case "$SWIPTERM_DISTRIBUTION" in
        ubuntu)
            if [ "$user" != ubuntu ]; then
                remove_template_user ubuntu
                rm -f /etc/sudoers.d/90-cloud-init-users
            fi
            ;;
        arch) remove_template_user alarm ;;
        esac
        create_user
        configure_sudo
        configure_doas
    elif [ -n "${SWIPTERM_PASSWORD:-}" ]; then
        printf 'root:%s\n' "$SWIPTERM_PASSWORD" | chpasswd
    fi

    load_user
    configure_login_shell
    configure_ssh
    configure_path
    configure_mirrors
    install_rust
    install_agents

    step "Done"
    """#
}
