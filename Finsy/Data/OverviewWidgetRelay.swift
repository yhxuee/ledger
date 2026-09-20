import Foundation
import WidgetKit

@MainActor
enum OverviewWidgetRelay {
    private static var lastKnownPrivacyMask: Bool?

    static func updateSnapshot(store: LedgerStore, preferences: AppPreferences? = nil) {
        let state = store.state
        let baseCurrency = state.settings.baseCurrency
        let isPrivacyMasked: Bool = {
            if let preferences {
                lastKnownPrivacyMask = preferences.biometricLockEnabled
                return preferences.biometricLockEnabled
            }
            if let cached = lastKnownPrivacyMask {
                return cached
            }
            if let loaded = AppPreferencesStore.load() {
                lastKnownPrivacyMask = loaded.biometricLockEnabled
                return loaded.biometricLockEnabled
            }
            let existing = OverviewWidgetSnapshotStore.readResult()
            if existing.state == .available {
                return existing.snapshot.isPrivacyMasked
            }
            return false
        }()

        let index = store.index

        // 1. Weekly activity
        let weeklySummary = LedgerCalculations.analytics(state, range: .week, type: .expense, accountID: nil, index: index)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let startOfWeek = calendar.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) ?? startOfToday
        let weeklyBuckets = weeklySummary.buckets.enumerated().map { offset, bucket in
            let date = calendar.date(byAdding: .day, value: offset, to: startOfWeek) ?? .now
            let label = date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
            return OverviewWidgetDailyBucket(id: bucket.id, label: label, amount: bucket.value)
        }

        // 2. Budget remain
        let usage = LedgerCalculations.budgetUsage(state, index: index)
        let hasBudget = usage.budget > 0
        let remaining = usage.budget - usage.spent
        let budgetData = OverviewWidgetBudgetData(
            budget: usage.budget,
            spent: usage.spent,
            remaining: remaining,
            ratio: usage.ratio,
            hasBudget: hasBudget
        )

        // 3. Today expense
        let todayStart = calendar.startOfDay(for: .now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)?.addingTimeInterval(-1) ?? .now
        let todaySummary = LedgerCalculations.analytics(state, range: .week, type: .expense, accountID: nil, customRange: todayStart...todayEnd, index: index)
        let expenseCats = state.categories.filter { $0.kind == .expense }
        let todaySegments = expenseCats.compactMap { cat -> OverviewWidgetCategorySegment? in
            let val = todaySummary.categoryTotals[cat.id, default: 0]
            guard val.isFinite, val > 0 else { return nil }
            return OverviewWidgetCategorySegment(id: cat.id.rawValue, name: cat.name, colorHex: cat.colorHex, amount: val)
        }

        // 4. Week expense
        let weekSegments = expenseCats.compactMap { cat -> OverviewWidgetCategorySegment? in
            let val = weeklySummary.categoryTotals[cat.id, default: 0]
            guard val.isFinite, val > 0 else { return nil }
            return OverviewWidgetCategorySegment(id: cat.id.rawValue, name: cat.name, colorHex: cat.colorHex, amount: val)
        }

        // 5. 6M Trends
        let sixMonthsSummary = LedgerCalculations.analytics(state, range: .sixMonths, type: .expense, accountID: nil, index: index)
        let sixMonthsBuckets = sixMonthsSummary.buckets.map { bucket in
            OverviewWidgetMonthlyBucket(id: bucket.id, label: bucket.label, amount: bucket.value)
        }

        let snapshot = OverviewWidgetSnapshot(
            schemaVersion: OverviewWidgetSnapshot.currentSchemaVersion,
            updatedAt: .now,
            currency: baseCurrency,
            isPrivacyMasked: isPrivacyMasked,
            weeklyActivity: .init(total: weeklySummary.total, buckets: weeklyBuckets),
            budgetRemain: budgetData,
            todayExpense: .init(total: todaySummary.total, segments: todaySegments),
            weekExpense: .init(total: weeklySummary.total, segments: weekSegments),
            sixMonthTrend: .init(total: sixMonthsSummary.total, buckets: sixMonthsBuckets)
        )

        let writeResult = OverviewWidgetSnapshotStore.writeAndVerify(snapshot)
        #if DEBUG
        OverviewWidgetSnapshotStore.logDiagnostics(process: "main-app")
        #endif

        if writeResult == .available {
            WidgetCenter.shared.reloadTimelines(ofKind: "FinsyOverviewMetric")
        }
    }

    static func updatePrivacyMask(isPrivacyMasked: Bool) {
        lastKnownPrivacyMask = isPrivacyMasked
        let result = OverviewWidgetSnapshotStore.readResult()
        guard result.state.isAvailable else { return }
        var snapshot = result.snapshot
        guard snapshot.isPrivacyMasked != isPrivacyMasked else { return }
        snapshot.isPrivacyMasked = isPrivacyMasked
        snapshot.updatedAt = .now
        let writeResult = OverviewWidgetSnapshotStore.writeAndVerify(snapshot)
        #if DEBUG
        OverviewWidgetSnapshotStore.logDiagnostics(process: "main-app-privacy")
        #endif
        if writeResult == .available {
            WidgetCenter.shared.reloadTimelines(ofKind: "FinsyOverviewMetric")
        }
    }

    @discardableResult
    static func refreshWidgetData(store: LedgerStore, preferences: AppPreferences? = nil) -> OverviewWidgetBridgeDiagnostics {
        updateSnapshot(store: store, preferences: preferences)
        return OverviewWidgetSnapshotStore.diagnostics()
    }
}
