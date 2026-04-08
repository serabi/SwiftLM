// AppearanceStore.swift -- Persists dark/light/system preference
import SwiftUI

final class AppearanceStore: ObservableObject {
    private static let key = "swiftlm.colorScheme"   // "dark" | "light" | "system"

    @Published var preference: String {
        didSet { UserDefaults.standard.set(preference, forKey: Self.key) }
    }

    init() {
        preference = UserDefaults.standard.string(forKey: Self.key) ?? "dark"
    }

    var colorScheme: ColorScheme? {
        switch preference {
        case "dark":  return .dark
        case "light": return .light
        default:      return nil
        }
    }
}

extension Notification.Name {
    static let showModelPicker = Notification.Name("showModelPicker")
}
