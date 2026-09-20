import AppIntents

struct AddTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Transaction"
    static let description = IntentDescription("Open Finsy to record a new transaction.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LedgerStore.shared.activeRoute = .addTransaction
        return .result()
    }
}

struct FinsyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTransactionIntent(),
            phrases: [
                "Add transaction in \(.applicationName)",
                "Record expense in \(.applicationName)",
                "New transaction in \(.applicationName)",
                "Log transaction in \(.applicationName)"
            ],
            shortTitle: "Add Transaction",
            systemImageName: "plus.circle.fill"
        )
    }
}
