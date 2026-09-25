import AppIntents
import Foundation

extension Notification.Name {
    static let nurseryListen = Notification.Name("nursery.listen")
}

/// "Hey Siri, listen to the nursery." It opens the app and turns on the live sound.
/// It also appears in Spotlight, in the Shortcuts app, and on the Action button.
struct ListenToNurseryIntent: AppIntent {
    static let title: LocalizedStringResource = "Listen to the Nursery"
    static let description = IntentDescription("Opens Nursery and starts the live sound from the baby's room.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .nurseryListen, object: nil)
        return .result()
    }
}

struct NurseryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListenToNurseryIntent(),
                    phrases: ["Listen to the nursery with \(.applicationName)",
                              "Start \(.applicationName)",
                              "Check the baby with \(.applicationName)"],
                    shortTitle: "Listen",
                    systemImageName: "ear")
    }
}
