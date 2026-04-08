// SwiftBuddyApp.swift -- App entry point (iOS + macOS)
import SwiftUI

@main
struct SwiftBuddyApp: App {
    @StateObject private var engine = InferenceEngine()
    @StateObject private var appearance = AppearanceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.colorScheme)
                .accentColor(SwiftBuddyTheme.accent)
                .tint(SwiftBuddyTheme.accent)
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Model") {
                Button("Choose Model…") {
                    NotificationCenter.default.post(name: .showModelPicker, object: nil)
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Unload Model") {
                    engine.unload()
                }
            }
        }
        #endif
    }
}

