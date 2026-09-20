import SwiftUI
import UserNotifications

struct RecordingReminderSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var store: LedgerStore
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private func slotTitle(for id: Int) -> String {
        switch id {
        case 1: "Morning Reminder"
        case 2: "Afternoon Reminder"
        case 3: "Evening Reminder"
        default: "Reminder \(id)"
        }
    }

    private func slotDefaultIcon(for id: Int) -> String {
        switch id {
        case 1: "sun.max"
        case 2: "sun.and.horizon"
        case 3: "moon.stars"
        default: "bell"
        }
    }

    private func bindingForSlot(_ slotID: Int) -> Binding<RecordingReminderSlot> {
        Binding(
            get: {
                preferences.value.recordingReminderSlots.first(where: { $0.id == slotID })
                    ?? RecordingReminderSlot(id: slotID, isEnabled: false, hour: 10, minute: 0)
            },
            set: { updatedSlot in
                preferences.update { prefs in
                    if let index = prefs.recordingReminderSlots.firstIndex(where: { $0.id == slotID }) {
                        prefs.recordingReminderSlots[index] = updatedSlot
                    } else {
                        prefs.recordingReminderSlots.append(updatedSlot)
                    }
                }
                Task {
                    await FinsyNotificationScheduler.shared.reconcileRecordingReminders(
                        slots: preferences.value.recordingReminderSlots
                    )
                }
            }
        )
    }

    private func timeBindingForSlot(_ slotID: Int) -> Binding<Date> {
        Binding(
            get: {
                let slot = preferences.value.recordingReminderSlots.first(where: { $0.id == slotID })
                let hour = slot?.hour ?? 10
                let minute = slot?.minute ?? 0
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = hour
                components.minute = minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let hour = components.hour ?? 10
                let minute = components.minute ?? 0
                preferences.update { prefs in
                    if let index = prefs.recordingReminderSlots.firstIndex(where: { $0.id == slotID }) {
                        prefs.recordingReminderSlots[index].hour = hour
                        prefs.recordingReminderSlots[index].minute = minute
                    }
                }
                Task {
                    await FinsyNotificationScheduler.shared.reconcileRecordingReminders(
                        slots: preferences.value.recordingReminderSlots
                    )
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if authorizationStatus == .denied {
                    SettingsGlassSection("Notification Access") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "bell.slash.fill")
                                    .foregroundStyle(.orange)
                                Text("Notifications Disabled")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("Finsy needs notification permission to send your daily bookkeeping reminders. Please enable notifications in iOS Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }

                SettingsGlassSection(
                    "Daily Reminders",
                    footer: "Configure up to three daily reminder times. Tapping a reminder notification opens Finsy directly to Add Expense."
                ) {
                    VStack(spacing: 0) {
                        ForEach(1...3, id: \.self) { slotID in
                            let slotBinding = bindingForSlot(slotID)
                            let timeBinding = timeBindingForSlot(slotID)

                            VStack(spacing: 8) {
                                HStack {
                                    SettingsLabel(slotTitle(for: slotID), systemImage: slotDefaultIcon(for: slotID))
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { slotBinding.wrappedValue.isEnabled },
                                        set: { enabled in
                                            if enabled && authorizationStatus != .authorized {
                                                Task {
                                                    let granted = await FinsyNotificationScheduler.shared.requestAuthorization()
                                                    authorizationStatus = await FinsyNotificationScheduler.shared.checkAuthorizationStatus()
                                                    if granted {
                                                        slotBinding.wrappedValue.isEnabled = true
                                                    }
                                                }
                                            } else {
                                                slotBinding.wrappedValue.isEnabled = enabled
                                            }
                                        }
                                    ))
                                    .labelsHidden()
                                }

                                if slotBinding.wrappedValue.isEnabled {
                                    HStack {
                                        Text("Reminder Time")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                                            .labelsHidden()
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.vertical, 8)

                            if slotID < 3 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Bookkeeping Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authorizationStatus = await FinsyNotificationScheduler.shared.checkAuthorizationStatus()
        }
    }
}
