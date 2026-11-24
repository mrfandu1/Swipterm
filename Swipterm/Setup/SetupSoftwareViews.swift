import SwiftUI

struct SetupSSH: Equatable {
    var isEnabled = false
    var port = String(SSHServer.defaultPort)
    var authentication = SSHAuthentication.password
    var authorizedKeys = ""

    var validPort: Int? {
        Int(port).flatMap { SSHServer.ports.contains($0) ? $0 : nil }
    }
}

struct SetupSSHView: View {
    @Binding var ssh: SetupSSH

    @State private var isEditingPublicKey = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $ssh.isEnabled) {
                    Text(verbatim: "SSH")
                }
                if ssh.isEnabled {
                    LabeledContent("Port") {
                        TextField("Port", text: $ssh.port, prompt: Text(verbatim: String(SSHServer.defaultPort)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
            }

            if ssh.isEnabled {
                Section("Authentication") {
                    Picker("Method", selection: $ssh.authentication) {
                        Text("Password")
                            .tag(SSHAuthentication.password)
                        Text("Public Key")
                            .tag(SSHAuthentication.publicKey)
                        Text("Password & Public Key")
                            .tag(SSHAuthentication.passwordAndPublicKey)
                    }
                    if ssh.authentication.allowsPublicKey {
                        Button {
                            isEditingPublicKey = true
                        } label: {
                            LabeledContent("Public Key") {
                                if ssh.authorizedKeys.isEmpty {
                                    Text("Not Configured")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Configured")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(FormColumnModifier())
        .navigationTitle(Text(verbatim: "SSH"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingPublicKey) {
            PublicKeySheet(authorizedKeys: $ssh.authorizedKeys)
        }
    }
}

private struct PublicKeySheet: View {
    @Binding var authorizedKeys: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(authorizedKeys: Binding<String>) {
        _authorizedKeys = authorizedKeys
        _text = State(initialValue: authorizedKeys.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 180)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(verbatim: "ssh-ed25519 AAAA…")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if !authorizedKeys.isEmpty {
                    Section {
                        Button("Delete", role: .destructive) {
                            authorizedKeys = ""
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        authorizedKeys = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SetupSoftwareView: View {
    @Binding var software: ContainerSoftware
    @Binding var ssh: SetupSSH
    let shells: [LoginShell]

    var body: some View {
        Form {
            Section {
                if !shells.isEmpty {
                    Picker("Shell", selection: $software.shell) {
                        ForEach(shells) { shell in
                            Text(verbatim: shell.displayName)
                                .tag(Optional(shell))
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
            }

            Section("Developer Tools") {
                ForEach(DeveloperTool.allCases, id: \.self) { tool in
                    let isSelected = software.developerTools.contains(tool)
                    SetupSelectionRow(title: tool.displayName, isSelected: isSelected) {
                        software.setDeveloperTool(tool, isEnabled: !isSelected)
                    }
                }
            }

            Section("Coding Agents") {
                ForEach(CodingAgent.allCases, id: \.self) { agent in
                    let isSelected = software.agents.contains(agent)
                    SetupSelectionRow(title: agent.displayName, isSelected: isSelected) {
                        software.setAgent(agent, isEnabled: !isSelected)
                    }
                }
            }

            let registries = software.registries
            if !registries.isEmpty {
                Section("Mirrors") {
                    ForEach(registries, id: \.self) { registry in
                        RegistryMirrorPicker(registry: registry, mirrorID: Binding {
                            software.registryMirrors[registry] ?? ""
                        } set: { mirrorID in
                            software.registryMirrors[registry] = mirrorID.isEmpty ? nil : mirrorID
                        })
                    }
                }
            }
        }
        .modifier(FormColumnModifier())
        .navigationTitle("Software")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetupSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RegistryMirrorPicker: View {
    let registry: PackageRegistry
    @Binding var mirrorID: String

    var body: some View {
        let mirrors = RegistryMirror.mirrors(for: registry)
        Picker(selection: $mirrorID) {
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
        } label: {
            Text(verbatim: registry.displayName)
        }
    }
}
