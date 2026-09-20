import Foundation
import SwiftUI

/// Coordinates background and lifecycle maintenance operations (rate refresh, quote sync,
/// notification reconciliation, widget snapshots) with in-flight deduplication to avoid
/// redundant concurrent work during cold launch and foreground transitions.
@MainActor
final class FinsyMaintenanceCoordinator {
    static let shared = FinsyMaintenanceCoordinator()

    private(set) var isPerformingMaintenance = false
    private(set) var lastMaintenanceDate: Date?

    private init() {}

    /// Performs cold-launch maintenance operations with in-flight deduplication.
    func performLaunchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) async {
        guard !isPerformingMaintenance else { return }
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }

        await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
        RecentTransactionActivityCoordinator.shared.registerObservers(store: store)
        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)
        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)
        _ = try? await store.refreshCurrencyCatalogIfNeeded()
        _ = try? await store.refreshExchangeRatesIfNeeded()
        await StockQuoteRefreshService.shared.refreshIfDue(store: store)
        MarketRefreshBackground.schedule(store: store)
        await FinsyNotificationScheduler.shared.reconcileAll(state: store.state, preferences: preferences.value)
        lastMaintenanceDate = .now
    }

    /// Performs foreground-transition maintenance operations with in-flight deduplication.
    func performForegroundMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) {
        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)
        store.reconcileSharedActivePurchases()
        store.processDueRecurring()
        store.refreshDueInstallments()
        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)

        guard !isPerformingMaintenance else { return }
        isPerformingMaintenance = true

        Task { @MainActor in
            defer { self.isPerformingMaintenance = false }
            await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
            _ = try? await store.refreshExchangeRatesIfNeeded()
            await StockQuoteRefreshService.shared.refreshIfDue(store: store)
            MarketRefreshBackground.schedule(store: store)
            await FinsyNotificationScheduler.shared.reconcileAll(state: store.state, preferences: preferences.value)
            self.lastMaintenanceDate = .now
        }
    }
}
