import Foundation
import SwiptermKit

nonisolated enum ContainerProvisioner {
    struct Request: Sendable {
        let hostname: String
        let user: String
        let password: String?
        let mirrorID: String?
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
        ]
        if let password = request.password, !password.isEmpty {
            environment["SWIPTERM_PASSWORD"] = password
        }

        if let distribution, let release {
            let source = await PackageMirrorResolver.resolve(for: distribution, release: release, mirrorID: request.mirrorID)
            switch source {
            case .upstream:
                await log(step("Package repositories: upstream defaults"))
            case let .mirror(name, root):
                await log(step("Package repositories: \(name) (\(root.url))"))
            }
            let configurator = PackageRepositoryConfigurator(fileSystem: runtime.fileSystem, distribution: distribution, release: release)
            for path in try await configurator.apply(source) {
                await log("    \(path)\r\n")
            }
            if distribution == .nixos {
                var substituters: [String]?
                if case let .mirror(_, root) = source, root.url != DistributionMirror.official.packages[.nixos]?.url {
                    substituters = [root.url, officialNixCache]
                }
                let module = nixOSSwiptermModule(
                    hostname: request.hostname,
                    user: request.user,
                    substituters: substituters,
                    stateVersion: release.versionID
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
        stateVersion: String?
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
        if user != "root" {
            lines += [
                "",
                "  users.users.\(literal(user)) = {",
                "    isNormalUser = true;",
                "    extraGroups = \(list(["wheel"]));",
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

    prepare_arch() {
        if [ -f /etc/locale.gen ] && have locale-gen; then
            step "Generating the en_US.UTF-8 locale"
            if ! grep -q '^en_US\.UTF-8 UTF-8' /etc/locale.gen; then
                if grep -q '^#[[:space:]]*en_US\.UTF-8 UTF-8' /etc/locale.gen; then
                    sed -i 's/^#[[:space:]]*\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
                else
                    printf 'en_US.UTF-8 UTF-8\n' >> /etc/locale.gen
                fi
            fi
            locale-gen
        fi
        step "Initializing the pacman keyring"
        pacman-key --init
        if [ -f /usr/share/pacman/keyrings/archlinuxarm.gpg ]; then
            pacman-key --populate archlinuxarm
        else
            pacman-key --populate
        fi
    }

    prepare_alpine() {
        if ! have sudo; then
            step "Installing sudo"
            apk add --no-cache sudo
        fi
    }

    prepare_gentoo() {
        if ! have sudo; then
            step "Syncing the Gentoo ebuild repository"
            emerge-webrsync
            step "Installing sudo"
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
        step "Installing the Linux kernel"
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
            if [ ! -d /var/db/repos/gentoo/profiles ]; then
                emerge-webrsync
            fi
            if ! emerge --ask=n --autounmask=n --getbinpkg=y --usepkgonly virtual/dist-kernel &&
                ! emerge --ask=n --autounmask=n --getbinpkg=y --usepkgonly sys-kernel/gentoo-kernel-bin; then
                warn "No prebuilt Gentoo kernel binary package is available; using the built-in kernel."
            fi
            ;;
        esac
    }

    remove_template_user() {
        template=$1
        [ "$template" != "$user" ] || return 0
        id "$template" >/dev/null 2>&1 || return 0
        step "Removing the template user $template"
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

    login_shell() {
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
            step "Configuring the user $user"
        else
            step "Creating the user $user"
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
        step "Allowing $user to use sudo without a password"
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
        step "Allowing $user to use doas without a password"
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

    case "$user" in
    root) ;;
    "" | -* | *[!A-Za-z0-9._-]*) fail "Invalid username: $user" ;;
    esac

    case "${SWIPTERM_DISTRIBUTION:-}" in
    nixos)
        step "Applying the NixOS configuration"
        if [ -n "${SWIPTERM_NIX_SUBSTITUTERS:-}" ]; then
            nixos-rebuild switch --option substituters "$SWIPTERM_NIX_SUBSTITUTERS"
        else
            nixos-rebuild switch
        fi
        if [ "$user" != root ] && [ -n "${SWIPTERM_PASSWORD:-}" ]; then
            printf '%s:%s\n' "$user" "$SWIPTERM_PASSWORD" | chpasswd
        fi
        step "Done"
        exit 0
        ;;
    arch) prepare_arch ;;
    alpine) prepare_alpine ;;
    gentoo) prepare_gentoo ;;
    esac

    if [ -n "${SWIPTERM_DISTRIBUTION:-}" ]; then
        install_kernel
    fi

    if [ "$user" != root ]; then
        case "${SWIPTERM_DISTRIBUTION:-}" in
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
    fi

    step "Done"
    """#
}
