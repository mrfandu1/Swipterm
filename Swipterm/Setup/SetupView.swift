import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SetupView: View {
    private enum Source: Hashable {
        case distribution(LinuxDistribution)
        case localArchive
        case archiveURL
    }

    private enum Field {
        case name
        case archiveURL
        case username
        case password
    }

    private let catalog = LinuxDistributionCatalogStore.shared
    private let system = LinuxSystem.shared

    @State private var source: Source = .distribution(.alpine)
    @State private var containerName = LinuxDistribution.alpine.defaultContainerName
    @State private var lastAutoContainerName = LinuxDistribution.alpine.defaultContainerName
    @State private var selectedReleaseID: String?
    @State private var initMode: ContainerInitMode = .managed
    @State private var mirrorID = ""
    @State private var customFileURL: URL?
    @State private var customRemoteURLText = ""
    @State private var showFileImporter = false
    @State private var usesRootUser = false
    @State private var username = ""
    @State private var lastAutoUsername = ""
    @State private var password = ""
    @State private var localHostName = LocalHostName()
    @State private var software = ContainerSoftware()
    @State private var ssh = SetupSSH()
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $containerName, prompt: Text(verbatim: "linux"))
                        .focused($focusedField, equals: .name)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Picker("Source", selection: clearingFocus($source)) {
                    ForEach(LinuxDistribution.allCases) { distribution in
                        Text(verbatim: distribution.displayName)
                            .tag(Source.distribution(distribution))
                    }
                    Section {
                        Text("Local Archive")
                            .tag(Source.localArchive)
                        Text("Archive URL")
                            .tag(Source.archiveURL)
                    }
                }

                switch source {
                case let .distribution(distribution):
                    SetupReleasePicker(
                        selectedReleaseID: clearingFocus($selectedReleaseID),
                        loadState: catalog.loadState,
                        releases: catalog.releases(for: distribution),
                        onRetryCatalog: {
                            Task { await catalog.refresh(mirror: selectedMirror) }
                        }
                    )
                case .localArchive:
                    Button {
                        focusedField = nil
                        showFileImporter = true
                    } label: {
                        LabeledContent("Archive") {
                            Text(customFileURL?.lastPathComponent ?? String(localized: "Choose File…"))
                                .foregroundStyle(customFileURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                case .archiveURL:
                    TextField("Archive URL", text: $customRemoteURLText, prompt: Text(verbatim: "https://example.com/rootfs.tar.xz"))
                        .focused($focusedField, equals: .archiveURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                if case .distribution = source, case let .failed(message) = catalog.loadState {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            let mirrors = availableMirrors
            if mirrors.count > 1 || showsStartupModePicker {
                Section("Configuration") {
                    if mirrors.count > 1 {
                        SetupMirrorPicker(mirrors: mirrors, mirrorID: clearingFocus($mirrorID))
                    }
                    if showsStartupModePicker {
                        StartupModePicker(selection: clearingFocus($initMode))
                    }
                }
            }

            Section {
                Toggle("Don’t Use Separate User", isOn: clearingFocus($usesRootUser))
                if !usesRootUser {
                    LabeledContent("Username") {
                        TextField("Username", text: $username, prompt: Text(verbatim: Self.fallbackUsername))
                            .focused($focusedField, equals: .username)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textContentType(.username)
                    }
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                        .focused($focusedField, equals: .password)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .textContentType(.newPassword)
                }
            } header: {
                Text("User")
            } footer: {
                if !usesRootUser, let problem = usernameProblem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }

            Section("Software") {
                if let distribution = selectedDistribution {
                    Picker("Shell", selection: clearingFocus(Binding {
                        software.shell ?? distribution.defaultShell
                    } set: { shell in
                        software.shell = shell
                    })) {
                        ForEach(distribution.shells(for: selectedRelease)) { shell in
                            Text(verbatim: shell.displayName)
                                .tag(shell)
                        }
                    }
                }
                NavigationLink {
                    SetupSSHView(ssh: $ssh)
                } label: {
                    LabeledContent {
                        Text(verbatim: ssh.isEnabled ? ssh.port : String(localized: "Off"))
                    } label: {
                        Text(verbatim: "SSH")
                    }
                }
                NavigationLink {
                    SetupDeveloperToolsView(software: $software)
                } label: {
                    LabeledContent(
                        "Developer Tools",
                        value: Self.summary(DeveloperTool.allCases.filter(software.developerTools.contains).map(\.shortName))
                    )
                }
                NavigationLink {
                    SetupAgentsView(software: $software)
                } label: {
                    LabeledContent(
                        "Agents",
                        value: Self.summary(CodingAgent.allCases.filter(software.agents.contains).map(\.shortName))
                    )
                }
            }

            Section {
                Button {
                    startInstall()
                } label: {
                    Text("Create")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canInstall)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.supportedArchiveTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                customFileURL = url
                applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Cannot Start Installation", isPresented: Binding {
            errorMessage != nil
        } set: { presented in
            if !presented {
                errorMessage = nil
            }
        }) {} message: {
            Text(errorMessage ?? "")
        }
        .task {
            await catalog.loadIfNeeded(mirror: selectedMirror)
            syncSelectedRelease()
        }
        .onAppear {
            applyAutoUsername(Self.suggestedUsername(fromHostName: localHostName.name))
            localHostName.start()
        }
        .onDisappear {
            localHostName.stop()
        }
        .onChange(of: localHostName.name) { _, name in
            applyAutoUsername(Self.suggestedUsername(fromHostName: name))
        }
        .onChange(of: source) { _, newSource in
            switch newSource {
            case let .distribution(distribution):
                applyAutoContainerName(distribution.defaultContainerName)
                syncSelectedRelease()
            case .localArchive:
                if let customFileURL {
                    applyAutoContainerName(Self.suggestedContainerName(fromArchive: customFileURL.lastPathComponent))
                }
            case .archiveURL:
                if let url = remoteArchiveURL {
                    applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
                }
            }
        }
        .onChange(of: customRemoteURLText) {
            if let url = remoteArchiveURL {
                applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
            }
        }
        .onChange(of: catalog.loadState) {
            syncSelectedRelease()
        }
        .onChange(of: selectedRelease) {
            if let shell = software.shell, let distribution = selectedDistribution,
               !distribution.shells(for: selectedRelease).contains(shell)
            {
                software.shell = nil
            }
        }
        .onChange(of: mirrorID) {
            Task { await catalog.refresh(mirror: selectedMirror) }
        }
    }

    private var selectedDistribution: LinuxDistribution? {
        if case let .distribution(distribution) = source {
            return distribution
        }
        return nil
    }

    private var selectedRelease: LinuxReleaseImage? {
        guard let distribution = selectedDistribution else { return nil }
        if let selectedReleaseID,
           let matched = catalog.releases(for: distribution).first(where: { $0.id == selectedReleaseID })
        {
            return matched
        }
        return catalog.defaultRelease(for: distribution)
    }

    private var selectedMirror: DistributionMirror? {
        DistributionMirror.all.first { $0.id == mirrorID }
    }

    private var availableMirrors: [DistributionMirror] {
        guard let distribution = selectedDistribution else { return [] }
        return DistributionMirror.all.filter { $0.serves(distribution) }
    }

    private var selectedSystemInit: SystemInit? {
        selectedDistribution?.systemInit(variant: selectedRelease?.variant)
    }

    private var showsStartupModePicker: Bool {
        selectedSystemInit == .systemd
    }

    private var effectiveInitMode: ContainerInitMode {
        guard let selectedSystemInit else { return .managed }
        return selectedSystemInit.requiredInitMode ?? initMode
    }

    private var remoteArchiveURL: URL? {
        let trimmed = customRemoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    private var usernameProblem: LocalizedStringResource? {
        if username == "root" {
            return "To use root, turn on Don’t Use Separate User."
        }
        guard !username.isEmpty, !Self.isValidUsername(username) else { return nil }
        return "Use up to 32 lowercase letters, digits, “_” and “-”, starting with a letter or “_”."
    }

    private var canInstall: Bool {
        guard usesRootUser || Self.isValidUsername(username) else { return false }
        switch source {
        case .distribution:
            return selectedRelease != nil
        case .localArchive:
            return customFileURL != nil
        case .archiveURL:
            return remoteArchiveURL != nil
        }
    }

    private func clearingFocus<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding {
            binding.wrappedValue
        } set: { newValue in
            focusedField = nil
            binding.wrappedValue = newValue
        }
    }

    private func applyAutoContainerName(_ suggested: String) {
        let trimmed = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || containerName == lastAutoContainerName {
            containerName = suggested
            lastAutoContainerName = suggested
        }
    }

    private func applyAutoUsername(_ suggested: String) {
        if username.isEmpty || username == lastAutoUsername {
            username = suggested
            lastAutoUsername = suggested
        }
    }

    private func syncSelectedRelease() {
        guard let distribution = selectedDistribution else { return }
        if let selectedReleaseID, catalog.releases(for: distribution).contains(where: { $0.id == selectedReleaseID }) {
            return
        }
        selectedReleaseID = catalog.defaultRelease(for: distribution)?.id
    }

    private func startInstall() {
        focusedField = nil
        let installSource: LinuxSystem.InstallRequest.Source
        switch source {
        case .distribution:
            guard let release = selectedRelease else { return }
            installSource = .catalog(release, mirror: selectedMirror)
        case .localArchive:
            guard let fileURL = customFileURL else { return }
            installSource = .localArchive(fileURL)
        case .archiveURL:
            guard let url = remoteArchiveURL else {
                errorMessage = String(localized: "Enter a valid HTTPS archive URL.")
                return
            }
            installSource = .remoteArchive(url)
        }
        guard usesRootUser || Self.isValidUsername(username) else { return }
        if password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errorMessage = String(localized: "The password can’t contain line breaks or control characters.")
            return
        }
        var software = software
        if software.shell == selectedDistribution?.defaultShell || selectedDistribution == nil {
            software.shell = nil
        }
        if ssh.isEnabled {
            guard let port = ssh.validPort else {
                errorMessage = String(localized: "Use a port from \(SSHServer.ports.lowerBound) to \(SSHServer.ports.upperBound).")
                return
            }
            if !ssh.authentication.allowsPublicKey, password.isEmpty {
                errorMessage = String(localized: "Set a password or allow public key authentication to sign in over SSH.")
                return
            }
            software.ssh = SSHServer(
                port: port,
                authentication: ssh.authentication,
                authorizedKeys: ssh.authentication.allowsPublicKey ? ssh.authorizedKeys : ""
            )
        }
        system.install(LinuxSystem.InstallRequest(
            source: installSource,
            containerName: Self.sanitizedContainerName(containerName),
            initMode: effectiveInitMode,
            user: usesRootUser ? "root" : username,
            password: password.isEmpty ? nil : password,
            software: software
        ))
    }

    private static func summary(_ names: [String]) -> String {
        names.isEmpty ? String(localized: "None") : names.formatted(.list(type: .and, width: .narrow))
    }

    private static var supportedArchiveTypes: [UTType] {
        var types: [UTType] = [.gzip, .bz2, .data]
        for ext in ["tar", "xz", "tgz", "txz", "tbz2"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private static var fallbackUsername: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "iphone"
        case .pad: "ipad"
        default: "linux"
        }
    }

    private static func isValidUsername(_ name: String) -> Bool {
        name != "root" && name.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) != nil
    }

    private static func suggestedUsername(fromHostName hostName: String?) -> String {
        var name = hostName?.lowercased() ?? ""
        while name.hasSuffix(".") {
            name.removeLast()
        }
        if name.hasSuffix(".local") {
            name.removeLast(".local".count)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        var sanitized = ""
        for character in name {
            if allowed.contains(character) {
                sanitized.append(character)
            } else if sanitized.last != "-" {
                sanitized.append("-")
            }
        }
        let leading = sanitized.drop { !$0.isLetter && $0 != "_" }
        let trimmed = String(leading.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return isValidUsername(trimmed) ? trimmed : fallbackUsername
    }

    private static func suggestedContainerName(fromArchive fileName: String) -> String {
        var name = fileName
        for suffix in [".tar.xz", ".tar.gz", ".tar.bz2", ".tar.lzma", ".txz", ".tgz", ".tbz2", ".tar"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return sanitizedContainerName(name)
    }

    private static func sanitizedContainerName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = String(raw.lowercased().map { allowed.contains($0) ? $0 : "-" })
        let collapsed = cleaned
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "linux" : String(collapsed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct SetupReleasePicker: View {
    @Binding var selectedReleaseID: String?
    let loadState: LinuxDistributionCatalogStore.LoadState
    let releases: [LinuxReleaseImage]
    let onRetryCatalog: () -> Void

    var body: some View {
        if !releases.isEmpty {
            Picker("Version", selection: Binding {
                selectedReleaseID ?? releases.first(where: \.isRecommended)?.id ?? releases.first?.id ?? ""
            } set: { newValue in
                selectedReleaseID = newValue
            }) {
                ForEach(releases) { release in
                    Text(verbatim: release.displayTitle)
                        .tag(release.id)
                }
            }
        } else {
            LabeledContent("Version") {
                switch loadState {
                case .idle, .loading:
                    ProgressView()
                case .loaded:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                case .failed:
                    Button("Retry", action: onRetryCatalog)
                }
            }
        }
    }
}

private struct SetupMirrorPicker: View {
    let mirrors: [DistributionMirror]
    @Binding var mirrorID: String

    var body: some View {
        Picker("Mirror", selection: Binding {
            mirrors.contains { $0.id == mirrorID } ? mirrorID : ""
        } set: { newValue in
            mirrorID = newValue
        }) {
            Text("Automatic")
                .tag("")
            ForEach(MirrorRegion.allCases, id: \.self) { region in
                let regionMirrors = mirrors.filter { $0.region == region }
                if !regionMirrors.isEmpty {
                    Section {
                        ForEach(regionMirrors) { mirror in
                            Text(verbatim: mirror.name)
                                .tag(mirror.id)
                        }
                    } header: {
                        Text(region.displayName)
                    }
                }
            }
        }
    }
}
