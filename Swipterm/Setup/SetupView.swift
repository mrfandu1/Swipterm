import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SetupDraft {
    enum Source: Hashable {
        case distribution(LinuxDistribution)
        case localArchive
        case archiveURL
    }

    var source = Source.distribution(.alpine)
    var containerName = LinuxDistribution.alpine.defaultContainerName
    var lastAutoContainerName = LinuxDistribution.alpine.defaultContainerName
    var selectedReleaseID: String?
    var initMode = ContainerInitMode.managed
    var mirrorID = ""
    var customFileURL: URL?
    var customRemoteURLText = ""
    var usesRootUser = false
    var username = ""
    var password = ""
    var software = ContainerSoftware(shell: .bash)
    var ssh = SetupSSH()
}

struct SetupView: View {
    private enum Field {
        case name
        case archiveURL
        case username
        case password
    }

    @Binding var draft: SetupDraft

    private let catalog = LinuxDistributionCatalogStore.shared
    private let system = LinuxSystem.shared

    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var catalogFailure: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.containerName, prompt: Text(verbatim: "linux"))
                        .focused($focusedField, equals: .name)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                            .accessibilityIdentifier("store-screenshot-setup")
                        #endif
                }

                Picker("Distribution", selection: clearingFocus($draft.source)) {
                    ForEach(LinuxDistribution.allCases) { distribution in
                        Text(verbatim: distribution.displayName)
                            .tag(SetupDraft.Source.distribution(distribution))
                    }
                    Section("Custom") {
                        Text("Local Archive")
                            .tag(SetupDraft.Source.localArchive)
                        Text("Archive URL")
                            .tag(SetupDraft.Source.archiveURL)
                    }
                }

                switch draft.source {
                case let .distribution(distribution):
                    SetupReleasePicker(
                        selectedReleaseID: clearingFocus($draft.selectedReleaseID),
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
                            Text(draft.customFileURL?.lastPathComponent ?? String(localized: "Choose File…"))
                                .foregroundStyle(draft.customFileURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                case .archiveURL:
                    TextField("Archive URL", text: $draft.customRemoteURLText, prompt: Text(verbatim: "https://example.com/rootfs.tar.xz"))
                        .focused($focusedField, equals: .archiveURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            Section("Configuration") {
                let mirrors = availableMirrors
                if mirrors.count > 1 {
                    SetupMirrorPicker(mirrors: mirrors, mirrorID: clearingFocus($draft.mirrorID))
                }
                if showsStartupModePicker {
                    StartupModePicker(selection: clearingFocus($draft.initMode))
                }
                NavigationLink {
                    SetupSoftwareView(
                        software: $draft.software,
                        ssh: $draft.ssh,
                        shells: selectedDistribution?.shells(for: selectedRelease) ?? []
                    )
                } label: {
                    LabeledContent("Software", value: softwareSummary)
                }
            }

            Section("User") {
                Toggle("Don’t Use Separate User", isOn: clearingFocus($draft.usesRootUser))
                if !draft.usesRootUser {
                    LabeledContent("Username") {
                        TextField("Username", text: $draft.username, prompt: Text(verbatim: Self.fallbackUsername))
                            .focused($focusedField, equals: .username)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                LabeledContent("Password") {
                    TextField("Password", text: $draft.password.masked { focusedField == .password }, prompt: Text("Optional"))
                        .focused($focusedField, equals: .password)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
        .modifier(FormColumnModifier())
        .navigationTitle("Swipterm Setup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.supportedArchiveTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                draft.customFileURL = url
                applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Can’t Create Container", isPresented: Binding {
            errorMessage != nil
        } set: { presented in
            if !presented {
                errorMessage = nil
            }
        }) {} message: {
            Text(errorMessage ?? "")
        }
        .alert("Couldn’t Load Versions", isPresented: Binding {
            catalogFailure != nil
        } set: { presented in
            if !presented {
                catalogFailure = nil
            }
        }, presenting: catalogFailure) { _ in
            Button("Retry") {
                Task { await catalog.refresh(mirror: selectedMirror) }
            }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure)
        }
        .task {
            await catalog.loadIfNeeded(mirror: selectedMirror)
            syncSelectedRelease()
        }
        .onChange(of: draft.source) { _, newSource in
            switch newSource {
            case let .distribution(distribution):
                applyAutoContainerName(distribution.defaultContainerName)
                syncSelectedRelease()
            case .localArchive:
                if let customFileURL = draft.customFileURL {
                    applyAutoContainerName(Self.suggestedContainerName(fromArchive: customFileURL.lastPathComponent))
                }
            case .archiveURL:
                if let url = remoteArchiveURL {
                    applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
                }
            }
        }
        .onChange(of: draft.customRemoteURLText) {
            if let url = remoteArchiveURL {
                applyAutoContainerName(Self.suggestedContainerName(fromArchive: url.lastPathComponent))
            }
        }
        .onChange(of: catalog.loadState) { _, loadState in
            syncSelectedRelease()
            if selectedDistribution != nil, case let .failed(message) = loadState {
                catalogFailure = message
            }
        }
        .onChange(of: selectedRelease) {
            if let shell = draft.software.shell, let distribution = selectedDistribution,
               !distribution.shells(for: selectedRelease).contains(shell)
            {
                draft.software.shell = .bash
            }
        }
        .onChange(of: draft.mirrorID) {
            Task { await catalog.refresh(mirror: selectedMirror) }
        }
    }

    private var selectedDistribution: LinuxDistribution? {
        if case let .distribution(distribution) = draft.source {
            return distribution
        }
        return nil
    }

    private var selectedRelease: LinuxReleaseImage? {
        guard let distribution = selectedDistribution else { return nil }
        if let selectedReleaseID = draft.selectedReleaseID,
           let matched = catalog.releases(for: distribution).first(where: { $0.id == selectedReleaseID })
        {
            return matched
        }
        return catalog.defaultRelease(for: distribution)
    }

    private var selectedMirror: DistributionMirror? {
        availableMirrors.first { $0.id == draft.mirrorID }
    }

    private var availableMirrors: [DistributionMirror] {
        guard let distribution = selectedDistribution else { return [] }
        return DistributionMirror.all.filter { $0.serves(distribution) }
    }

    private var selectedSystemInit: SystemInit? {
        selectedDistribution?.systemInit
    }

    private var showsStartupModePicker: Bool {
        selectedSystemInit == .systemd
    }

    private var effectiveInitMode: ContainerInitMode {
        guard let selectedSystemInit else { return .managed }
        return selectedSystemInit.requiredInitMode ?? draft.initMode
    }

    private var remoteArchiveURL: URL? {
        let trimmed = draft.customRemoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            return nil
        }
        return url
    }

    private var softwareSummary: String {
        let shell = (draft.software.shell ?? .bash).displayName
        let count = draft.software.developerTools.count + draft.software.agents.count + (draft.ssh.isEnabled ? 1 : 0)
        return count == 0 ? shell : "\(shell) + \(count)"
    }

    private var usernameProblem: LocalizedStringResource? {
        if draft.username == "root" {
            return "To use root, turn on Don’t Use Separate User."
        }
        guard !draft.username.isEmpty, !Self.isValidUsername(draft.username) else { return nil }
        return "Use up to 32 lowercase letters, digits, underscores (_), and hyphens (-), starting with a letter or underscore."
    }

    private var canInstall: Bool {
        switch draft.source {
        case .distribution:
            return selectedRelease != nil
        case .localArchive:
            return draft.customFileURL != nil
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
        let trimmed = draft.containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || draft.containerName == draft.lastAutoContainerName {
            draft.containerName = suggested
            draft.lastAutoContainerName = suggested
        }
    }

    private func syncSelectedRelease() {
        guard let distribution = selectedDistribution else { return }
        if let selectedReleaseID = draft.selectedReleaseID,
           catalog.releases(for: distribution).contains(where: { $0.id == selectedReleaseID })
        {
            return
        }
        draft.selectedReleaseID = catalog.defaultRelease(for: distribution)?.id
    }

    private func startInstall() {
        focusedField = nil
        let installSource: LinuxSystem.InstallRequest.Source
        switch draft.source {
        case .distribution:
            guard let release = selectedRelease else { return }
            installSource = .catalog(release, mirror: selectedMirror)
        case .localArchive:
            guard let fileURL = draft.customFileURL else { return }
            installSource = .localArchive(fileURL)
        case .archiveURL:
            guard let url = remoteArchiveURL else {
                errorMessage = String(localized: "Enter a valid archive URL.")
                return
            }
            installSource = .remoteArchive(url)
        }
        if !draft.usesRootUser, let usernameProblem {
            errorMessage = String(localized: usernameProblem)
            return
        }
        if draft.password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            errorMessage = String(localized: "The password can’t contain line breaks or control characters.")
            return
        }
        var software = draft.software
        if selectedDistribution == nil {
            software.shell = nil
        }
        if draft.ssh.isEnabled {
            guard let port = draft.ssh.validPort else {
                errorMessage = String(localized: "Use a port from \(SSHServer.ports.lowerBound) to \(SSHServer.ports.upperBound).")
                return
            }
            if !draft.ssh.authentication.allowsPublicKey, draft.password.isEmpty {
                errorMessage = String(localized: "Set a password or allow public key authentication to sign in over SSH.")
                return
            }
            software.ssh = SSHServer(
                port: port,
                authentication: draft.ssh.authentication,
                authorizedKeys: draft.ssh.authentication.allowsPublicKey ? draft.ssh.authorizedKeys : ""
            )
        }
        system.install(LinuxSystem.InstallRequest(
            source: installSource,
            containerName: Self.sanitizedContainerName(draft.containerName),
            initMode: effectiveInitMode,
            user: draft.usesRootUser ? "root" : draft.username.isEmpty ? Self.fallbackUsername : draft.username,
            password: draft.password.isEmpty ? nil : draft.password,
            software: software
        ))
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

    static var fallbackUsername: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "iphone"
        case .pad: "ipad"
        default: "linux"
        }
    }

    private static func isValidUsername(_ name: String) -> Bool {
        name != "root" && name.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) != nil
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

struct FormColumnModifier: ViewModifier {
    private static let maxWidth: CGFloat = 640

    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = (width - Self.maxWidth) / 2
        content
            .contentMargins(.horizontal, margin > 20 ? margin : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                width = newWidth
            }
    }
}

private extension Binding<String> {
    func masked(revealed: @escaping () -> Bool) -> Binding<String> {
        Binding {
            revealed() ? wrappedValue : String(repeating: "•", count: wrappedValue.count)
        } set: {
            if revealed() {
                wrappedValue = $0
            }
        }
    }
}
