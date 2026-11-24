import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let terminalAppearanceDidChange = Notification.Name("AppSettings.terminalAppearanceDidChange")
    static let defaultLightTheme = "Alabaster"
    static let defaultDarkTheme = "Afterglow"

    private enum Key {
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let lightConfig = "lightConfig"
        static let darkConfig = "darkConfig"
        static let fontFollowTheme = "fontFollowTheme"
        static let fontFamily = "fontFamily"
        static let fontSize = "fontSize"
        static let caffeinateAvailable = "caffeinateAvailable"
        static let caffeinateEnabled = "caffeinateEnabled"
    }

    var lightTheme: String {
        didSet { saveTerminalAppearance(lightTheme, for: Key.lightTheme) }
    }

    var darkTheme: String {
        didSet { saveTerminalAppearance(darkTheme, for: Key.darkTheme) }
    }

    var lightConfig: String {
        didSet { saveTerminalAppearance(lightConfig, for: Key.lightConfig) }
    }

    var darkConfig: String {
        didSet { saveTerminalAppearance(darkConfig, for: Key.darkConfig) }
    }

    var fontFollowTheme: Bool {
        didSet { saveTerminalAppearance(fontFollowTheme, for: Key.fontFollowTheme) }
    }

    var fontFamily: String {
        didSet { saveTerminalAppearance(fontFamily, for: Key.fontFamily) }
    }

    var fontSize: Double {
        didSet { saveTerminalAppearance(fontSize, for: Key.fontSize) }
    }

    var isCaffeinateAvailable: Bool {
        didSet { store.set(isCaffeinateAvailable, for: Key.caffeinateAvailable) }
    }

    var isCaffeinateEnabled: Bool {
        didSet { store.set(isCaffeinateEnabled, for: Key.caffeinateEnabled) }
    }

    private let store = PreferenceStore.shared

    private init() {
        lightTheme = store.value(String.self, for: Key.lightTheme) ?? Self.defaultLightTheme
        darkTheme = store.value(String.self, for: Key.darkTheme) ?? Self.defaultDarkTheme
        lightConfig = store.value(String.self, for: Key.lightConfig) ?? ""
        darkConfig = store.value(String.self, for: Key.darkConfig) ?? ""
        fontFollowTheme = store.value(Bool.self, for: Key.fontFollowTheme) ?? true
        fontFamily = store.value(String.self, for: Key.fontFamily) ?? ""
        fontSize = store.value(Double.self, for: Key.fontSize) ?? 10
        isCaffeinateAvailable = store.value(Bool.self, for: Key.caffeinateAvailable) ?? false
        isCaffeinateEnabled = store.value(Bool.self, for: Key.caffeinateEnabled) ?? false
    }

    private func saveTerminalAppearance(_ value: some Encodable, for name: String) {
        store.set(value, for: name)
        NotificationCenter.default.post(name: Self.terminalAppearanceDidChange, object: self)
    }
}
