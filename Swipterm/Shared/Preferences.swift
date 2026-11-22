import Foundation
import SwiftUI

nonisolated struct Preference<Value: Sendable>: Sendable {
    let key: String
    let defaultValue: Value

    var value: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

nonisolated enum Preferences {
    static let lightTheme = Preference(key: "ghostty_light_theme", defaultValue: "Alabaster")
    static let darkTheme = Preference(key: "ghostty_dark_theme", defaultValue: "Afterglow")
    static let lightConfig = Preference(key: "ghostty_light_config", defaultValue: "")
    static let darkConfig = Preference(key: "ghostty_dark_config", defaultValue: "")
    static let fontFollowTheme = Preference(key: "terminal_font_follow_theme", defaultValue: true)
    static let fontFamily = Preference(key: "terminal_font_family", defaultValue: "")
    static let fontSize = Preference(key: "terminal_font_size", defaultValue: 10.0)
    static let alwaysShowSymbolBar = Preference(key: "always_show_symbol_bar", defaultValue: false)
    static let keepScreenAwake = Preference(key: "keep_screen_awake", defaultValue: false)
    static let resetContainerOnLaunch = Preference(key: "reset_container_on_launch", defaultValue: false)
    static let distributionMirror = Preference(key: "distribution_mirror", defaultValue: "")
}

extension AppStorage where Value == String {
    init(_ preference: Preference<String>) {
        self.init(wrappedValue: preference.defaultValue, preference.key)
    }
}

extension AppStorage where Value == Bool {
    init(_ preference: Preference<Bool>) {
        self.init(wrappedValue: preference.defaultValue, preference.key)
    }
}

extension AppStorage where Value == Double {
    init(_ preference: Preference<Double>) {
        self.init(wrappedValue: preference.defaultValue, preference.key)
    }
}
