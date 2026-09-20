import Foundation
import UIKit
import UserNotifications

@MainActor
final class FinsyNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FinsyNotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    override private init() {
        super.init()
        center.delegate = self
    }

    func configure() {
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func reconcileAll(state: LedgerState, preferences: AppPreferences) async {
        let status = await checkAuthorizationStatus()
        guard status == .authorized || status == .provisional else {
            return
        }

        await reconcileRecordingReminders(slots: preferences.recordingReminderSlots)
        await reconcileCouponReminders(accounts: state.accounts)
        await reconcileStatementReminders(preferences: preferences)
    }

    func rescheduleRecordingReminders(slots: [RecordingReminderSlot]) {
        Task {
            await reconcileRecordingReminders(slots: slots)
        }
    }

    func rescheduleCouponReminders(accounts: [LedgerAccount]) {
        Task {
            await reconcileCouponReminders(accounts: accounts)
        }
    }

    func rescheduleMonthlyStatementReminder(preferences: AppPreferences) {
        Task {
            await reconcileStatementReminders(preferences: preferences)
        }
    }

    func reconcileRecordingReminders(slots: [RecordingReminderSlot]) async {
        for slot in slots {
            let identifier = "recording.slot.\(slot.id)"
            center.removePendingNotificationRequests(withIdentifiers: [identifier])

            guard slot.isEnabled else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Bookkeeping Reminder"
            content.body = "Take a moment to record your latest expenses."
            content.sound = .default
            content.userInfo = ["url": "finsy://transaction/add"]

            var dateComponents = DateComponents()
            dateComponents.hour = slot.hour
            dateComponents.minute = slot.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            try? await center.add(request)
        }
    }

    func reconcileCouponReminders(accounts: [LedgerAccount]) async {
        let pending = await center.pendingNotificationRequests()
        let existingCouponIDs = Set(pending.filter { $0.identifier.hasPrefix("coupon.") }.map(\.identifier))

        var activeCouponIdentifiers = Set<String>()
        let calendar = Calendar.current
        let now = Date()

        for account in accounts where account.type == .eWallet {
            guard let coupons = account.coupons else { continue }
            for coupon in coupons {
                guard coupon.usedAt == nil, coupon.reminderEnabled else { continue }
                guard coupon.expirationDate > now else { continue }

                guard let reminderDate = calendar.date(byAdding: .day, value: -1, to: coupon.expirationDate) else { continue }
                var reminderComponents = calendar.dateComponents([.year, .month, .day], from: reminderDate)
                reminderComponents.hour = 9
                reminderComponents.minute = 0
                reminderComponents.second = 0

                guard let finalReminderDate = calendar.date(from: reminderComponents), finalReminderDate > now else {
                    continue
                }

                let identifier = "coupon.\(coupon.id.uuidString)"
                activeCouponIdentifiers.insert(identifier)

                let content = UNMutableNotificationContent()
                content.title = "Coupon Expiring Soon"
                content.body = "\(coupon.name) (\(LedgerFormat.money(coupon.faceValue, currency: coupon.currency))) expires tomorrow."
                content.sound = .default

                let targetComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: finalReminderDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: targetComponents, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

                try? await center.add(request)
            }
        }

        let toRemove = Array(existingCouponIDs.subtracting(activeCouponIdentifiers))
        if !toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toRemove)
        }
    }

    func reconcileStatementReminders(preferences: AppPreferences) async {
        let pending = await center.pendingNotificationRequests()
        let existingStatementIDs = pending.filter { $0.identifier.hasPrefix("statement.") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: existingStatementIDs)

        guard preferences.monthlyStatementReminderEnabled else { return }

        let calendar = Calendar.current
        let now = Date()

        for monthOffset in 0..<12 {
            guard let targetMonth = calendar.date(byAdding: .month, value: monthOffset, to: now) else { continue }
            guard let monthRange = calendar.range(of: .day, in: .month, for: targetMonth) else { continue }
            let lastDay = monthRange.count

            var comp = calendar.dateComponents([.year, .month], from: targetMonth)
            comp.day = lastDay
            comp.hour = preferences.monthlyStatementReminderHour
            comp.minute = preferences.monthlyStatementReminderMinute
            comp.second = 0

            guard let fireDate = calendar.date(from: comp), fireDate > now else { continue }

            let year = comp.year ?? 0
            let month = comp.month ?? 0
            let identifier = "statement.\(year).\(month)"

            let formatter = DateFormatter()
            formatter.dateFormat = "LLLL"
            let monthName = formatter.string(from: fireDate)

            let content = UNMutableNotificationContent()
            content.title = "Finsy Statement Ready"
            content.body = "Your Finsy Statement for \(monthName) is ready to review."
            content.sound = .default

            let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            try? await center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix("recording.slot.") {
            DispatchQueue.main.async {
                if let url = URL(string: "finsy://transaction/add") {
                    UIApplication.shared.open(url)
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
