import SwiftUI
import UIKit

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct StatementShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct StatementConfigurationSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let type: StatementType

    @State private var selectedMonth: Date = .now
    @State private var showingMonthPicker = false
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var isGenerating = false
    @State private var shareItem: ShareSheetItem?
    @State private var errorMessage: String?

    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }

    private var monthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }

    private var activeAccounts: [LedgerAccount] {
        store.accounts.map(\.account).filter { $0.deletedAt == nil }
    }

    private var allSelected: Bool {
        selectedAccountIDs.count == activeAccounts.count && !activeAccounts.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Statement Period") {
                    Button {
                        showingMonthPicker = true
                    } label: {
                        HStack {
                            Text("Month")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(monthFormatter.string(from: selectedMonth))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    Toggle("Select All Accounts", isOn: Binding(
                        get: { allSelected },
                        set: { selectAll in
                            if selectAll {
                                selectedAccountIDs = Set(activeAccounts.map(\.id))
                            } else {
                                selectedAccountIDs.removeAll()
                            }
                        }
                    ))

                    ForEach(activeAccounts) { account in
                        Button {
                            if selectedAccountIDs.contains(account.id) {
                                selectedAccountIDs.remove(account.id)
                            } else {
                                selectedAccountIDs.insert(account.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                if account.effectiveIsFrozen {
                                    Text("Frozen")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                                if selectedAccountIDs.contains(account.id) {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(primaryActionColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Accounts (\(selectedAccountIDs.count)/\(activeAccounts.count))")
                }

                Section("Reminder") {
                    Toggle("Month-End Statement Reminder", isOn: Binding(
                        get: { preferences.value.monthlyStatementReminderEnabled },
                        set: { enabled in
                            preferences.update { $0.monthlyStatementReminderEnabled = enabled }
                            Task {
                                if enabled {
                                    _ = await FinsyNotificationScheduler.shared.requestAuthorization()
                                }
                                await FinsyNotificationScheduler.shared.reconcileStatementReminders(preferences: preferences.value)
                            }
                        }
                    ))
                    Text("Receive a notification on the last day of each month to review and export your statements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        generateStatement()
                    } label: {
                        HStack {
                            Spacer()
                            if isGenerating {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isGenerating ? "Generating..." : "Generate PDF")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(primaryActionColor)
                    .disabled(selectedAccountIDs.isEmpty || isGenerating)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }
            .navigationTitle(type.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if selectedAccountIDs.isEmpty {
                    selectedAccountIDs = Set(activeAccounts.map(\.id))
                }
            }
            .sheet(item: $shareItem) { item in
                StatementShareSheet(activityItems: [item.url])
            }
            .sheet(isPresented: $showingMonthPicker) {
                MonthYearPickerSheet(selectedDate: $selectedMonth)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func generateStatement() {
        isGenerating = true
        let accounts = activeAccounts.filter { selectedAccountIDs.contains($0.id) }

        Task {
            do {
                let url: URL
                switch type {
                case .monthly:
                    url = try StatementPDFGenerator.generateMonthlyStatement(
                        monthDate: selectedMonth,
                        accounts: accounts,
                        in: store.state
                    )
                case .tax:
                    url = try StatementPDFGenerator.generateTaxStatement(
                        monthDate: selectedMonth,
                        accounts: accounts,
                        in: store.state
                    )
                }
                await MainActor.run {
                    isGenerating = false
                    shareItem = ShareSheetItem(url: url)
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
