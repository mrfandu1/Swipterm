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
            } footer: {
                if ssh.isEnabled, ssh.validPort == nil {
                    Text("Use a port from \(SSHServer.ports.lowerBound) to \(SSHServer.ports.upperBound).")
                        .foregroundStyle(.red)
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

struct SetupDeveloperToolsView: View {
    @Binding var software: ContainerSoftware

    var body: some View {
        Form {
            Section {
                toggle(.node)
                toggle(.pnpm)
                toggle(.bun)
            } header: {
                Text(verbatim: "Node")
            }
            Section {
                toggle(.go)
            } header: {
                Text(verbatim: "Go")
            }
        }
        .navigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ tool: DeveloperTool) -> some View {
        Toggle(isOn: Binding {
            software.developerTools.contains(tool)
        } set: { isEnabled in
            software.setDeveloperTool(tool, isEnabled: isEnabled)
        }) {
            Text(verbatim: tool.displayName)
        }
    }
}

struct SetupAgentsView: View {
    @Binding var software: ContainerSoftware

    var body: some View {
        Form {
            ForEach(CodingAgent.allCases, id: \.self) { agent in
                Toggle(isOn: Binding {
                    software.agents.contains(agent)
                } set: { isEnabled in
                    software.setAgent(agent, isEnabled: isEnabled)
                }) {
                    Text(verbatim: agent.displayName)
                }
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }
}
