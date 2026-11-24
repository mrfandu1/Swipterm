import SwiftUI

struct SettingsView: View {
    private let system = LinuxSystem.shared

    @Environment(\.dismiss) private var dismiss
    @State private var dataSize: Int64?
    @State private var isConfirmingReset = false
    @State private var isPromptingRestart = false

    var body: some View {
        Form {
            Section("Terminal") {
                NavigationLink("Ghostty Configuration") {
                    GhosttyConfigurationView()
                }
            }
            if let container = system.installedContainer {
                Section("Container") {
                    LabeledContent("Data Size") {
                        if let dataSize {
                            Text(dataSize.formatted(.byteCount(style: .file)))
                        }
                    }
                    if container.systemInit == .systemd {
                        StartupModePicker(selection: Binding {
                            container.initMode
                        } set: { initMode in
                            guard initMode != container.initMode else { return }
                            system.updateInitMode(initMode)
                            if initMode != system.activeInitMode {
                                isPromptingRestart = true
                            }
                        })
                    }
                    Button("Reset", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .confirmationDialog("Reset Container?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) {
                            dismiss()
                            system.reset()
                        }
                    } message: {
                        Text("All files and packages in the container will be erased, and you’ll return to setup.")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard system.installedContainer != nil else { return }
            dataSize = await Task.detached(priority: .utility) { LinuxSystem.containerDataSize() }.value
        }
        .alert("Restart Required", isPresented: $isPromptingRestart) {
            Button("Restart Now") {
                dismiss()
                system.restart()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Restart the container to apply the new startup mode.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
