import AppIntents
import Foundation

extension Notification.Name {
    static let nurseryListen = Notification.Name("nursery.listen")
}

/// It opens the app and turns on the live sound. It appears in Spotlight, in the Shortcuts app,
/// and on the Action button. Siri does not speak Czech, so the spoken phrases stay in English.
struct ListenToNurseryIntent: AppIntent {
    static let title: LocalizedStringResource = "Poslouchat dětský pokoj"
    static let description = IntentDescription("Otevře Chůvičku a spustí živý zvuk z dětského pokoje.")
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
                    shortTitle: "Poslouchat",
                    systemImageName: "ear")
    }
}
