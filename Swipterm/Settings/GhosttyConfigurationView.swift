import SwiftUI

struct GhosttyConfigurationView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var lightPickerTheme: String?
    @State private var darkPickerTheme: String?

    var body: some View {
        Form {
            schemeSection(
                "Light Configuration",
                scheme: .light,
                theme: $settings.lightTheme,
                pickerTheme: $lightPickerTheme,
                defaultTheme: AppSettings.defaultLightTheme
            )
            schemeSection(
                "Dark Configuration",
                scheme: .dark,
                theme: $settings.darkTheme,
                pickerTheme: $darkPickerTheme,
                defaultTheme: AppSettings.defaultDarkTheme
            )
            Section("Font Configuration") {
                Toggle("Follow Theme", isOn: $settings.fontFollowTheme)
                if !settings.fontFollowTheme {
                    NavigationLink {
                        FontPickerView(selection: $settings.fontFamily)
                    } label: {
                        LabeledContent("Font", value: settings.fontFamily.isEmpty ? String(localized: "Follow Theme") : settings.fontFamily)
                    }
                    Stepper(value: $settings.fontSize, in: 8 ... 32, step: 1) {
                        LabeledContent("Size") {
                            Text(verbatim: "\(Int(settings.fontSize))")
                                .monospacedDigit()
                        }
                    }
                }
            }
            Section {
                Toggle("Always Show Symbol Bar", isOn: $settings.alwaysShowSymbolBar)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The symbol bar is hidden while a hardware keyboard is connected unless this is enabled.")
            }
        }
        .navigationTitle("Ghostty Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func schemeSection(
        _ header: LocalizedStringKey,
        scheme: ThemePickerView.Scheme,
        theme: Binding<String>,
        pickerTheme: Binding<String?>,
        defaultTheme: String
    ) -> some View {
        let isCustom = theme.wrappedValue.isEmpty
        return Section(header) {
            NavigationLink {
                ThemePickerView(scheme: scheme, selection: theme)
            } label: {
                LabeledContent("Theme", value: isCustom ? pickerTheme.wrappedValue ?? defaultTheme : theme.wrappedValue)
            }
            .disabled(isCustom)
            Toggle("Custom Configuration", isOn: Binding {
                isCustom
            } set: { enabled in
                if enabled {
                    pickerTheme.wrappedValue = theme.wrappedValue
                    theme.wrappedValue = ""
                } else {
                    theme.wrappedValue = pickerTheme.wrappedValue ?? defaultTheme
                }
            })
            if isCustom {
                NavigationLink("Edit Custom Configuration") {
                    EditGhosttyConfigView(scheme: scheme)
                }
            }
        }
    }
}
