import SwiftUI

struct GhosttyConfigurationView: View {
    @AppStorage(Preferences.lightTheme) private var lightTheme: String
    @AppStorage(Preferences.darkTheme) private var darkTheme: String
    @AppStorage(Preferences.fontFollowTheme) private var fontFollowTheme: Bool
    @AppStorage(Preferences.fontFamily) private var fontFamily: String
    @AppStorage(Preferences.fontSize) private var fontSize: Double
    @AppStorage(Preferences.alwaysShowSymbolBar) private var alwaysShowSymbolBar: Bool
    @State private var lightPickerTheme: String?
    @State private var darkPickerTheme: String?

    var body: some View {
        Form {
            schemeSection(
                "Light Configuration",
                scheme: .light,
                theme: $lightTheme,
                pickerTheme: $lightPickerTheme,
                defaultTheme: Preferences.lightTheme.defaultValue
            )
            schemeSection(
                "Dark Configuration",
                scheme: .dark,
                theme: $darkTheme,
                pickerTheme: $darkPickerTheme,
                defaultTheme: Preferences.darkTheme.defaultValue
            )
            Section("Font Configuration") {
                Toggle("Follow Theme", isOn: $fontFollowTheme)
                if !fontFollowTheme {
                    NavigationLink {
                        FontPickerView(selection: $fontFamily)
                    } label: {
                        LabeledContent("Font", value: fontFamily.isEmpty ? String(localized: "Follow Theme") : fontFamily)
                    }
                    Stepper(value: $fontSize, in: 8 ... 32, step: 1) {
                        LabeledContent("Size") {
                            Text(verbatim: "\(Int(fontSize))")
                                .monospacedDigit()
                        }
                    }
                }
            }
            Section {
                Toggle("Always Show Symbol Bar", isOn: $alwaysShowSymbolBar)
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
