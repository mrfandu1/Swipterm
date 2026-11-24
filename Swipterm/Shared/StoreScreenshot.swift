#if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
    import Foundation

    enum StoreScreenshot: String {
        case setup
        case terminal

        static let current: Self? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--store-screenshot"), flag + 1 < arguments.count else {
                return nil
            }
            return Self(rawValue: arguments[flag + 1])
        }()

        static let alpineVersion = "3.24.4"

        static let alpineRelease = LinuxReleaseImage(
            id: "alpine-3.24-arm64",
            distribution: .alpine,
            releaseKey: "3.24",
            displayTitle: "3.24",
            buildSerial: "",
            artifactPath: "",
            sortRank: 0,
            isRecommended: true
        )

        static func transcript(username: String) -> String {
            let escape = "\u{1B}"
            let prompt = "\(escape)[32m\(username)@alpine\(escape)[0m:\(escape)[34m~\(escape)[0m$ "
            let directory = { (name: String) in "\(escape)[34m\(name)\(escape)[0m" }
            return [
                "\(escape)]0;Alpine\u{07}\(escape)]7;file://alpine/home/\(username)\u{07}",
                prompt + "cat /etc/alpine-release",
                alpineVersion,
                "",
                prompt + "echo \"$SHELL\"",
                "/bin/bash",
                "",
                prompt + "pwd",
                "/home/\(username)",
                "",
                prompt + "ls --color=auto /",
                ["bin", "dev", "etc", "home", "lib", "media"].map(directory).joined(separator: "  "),
                ["mnt", "opt", "proc", "root", "run", "sbin"].map(directory).joined(separator: "  "),
                ["srv", "sys", "tmp", "usr", "var"].map(directory).joined(separator: "  "),
                "",
                prompt,
            ].joined(separator: "\r\n")
        }
    }
#endif
