import SwiftUI

struct SettingsView: View {
    private let system = LinuxSystem.shared

    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared
    @State private var isConfirmingReset = false
    @State private var isPromptingRestart = false

    var body: some View {
        Form {
            Section("Terminal") {
                NavigationLink("Ghostty Configuration") {
                    GhosttyConfigurationView()
                }
                Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake)
            }
            if let container = system.installedContainer {
                Section("Container") {
                    if container.distribution?.requiresSystemInit != true {
                        StartupModePicker(selection: Binding {
                            container.initMode
                        } set: { initMode in
                            guard initMode != container.initMode else { return }
                            system.updateInitMode(initMode)
                            if initMode != system.activeInitMode {
                                isPromptingRestart = true
                            }
                        }, nativeInitSystem: container.nativeInitSystem)
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
                        Text("All files and installed packages inside the container will be erased and you will return to setup.")
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: version)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "") (\(info["CFBundleVersion"] ?? ""))"
    }
}
