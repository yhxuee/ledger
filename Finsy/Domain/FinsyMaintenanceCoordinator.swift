import Foundation
import SwiftUI

/// Coordinates background and lifecycle maintenance operations (rate refresh, quote sync,
/// notification reconciliation, widget snapshots) with distinct separation between
/// process-level launch maintenance and book-level ledger switch reconciliation.
@MainActor
final class FinsyMaintenanceCoordinator {
    static let shared = FinsyMaintenanceCoordinator()

    private(set) var hasPerformedAppLaunch = false
    private(set) var isPerformingBackgroundMaintenance = false
    private(set) var lastMaintenanceDate: Date?

    private init() {}

    /// Performs one-time app-launch maintenance operations (biometrics, observers, migrations,
    /// catalog/rates/quotes refresh, background tasks).
    func performAppLaunchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) async {
        guard !hasPerformedAppLaunch else { return }
        hasPerformedAppLaunch = true

        await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
        await store.resumeEncryptionMigrations()
        RecentTransactionActivityCoordinator.shared.registerObservers(store: store)

        // Perform initial book-specific reconciliation
        performLedgerSwitchMaintenance(store: store, preferences: preferences)

        _ = try? await store.refreshCurrencyCatalogIfNeeded()
        _ = try? await store.refreshExchangeRatesIfNeeded()
        await StockQuoteRefreshService.shared.refreshIfDue(store: store)
        MarketRefreshBackground.schedule(store: store)
        await FinsyNotificationScheduler.shared.reconcileAll(state: store.state, preferences: preferences.value)
        lastMaintenanceDate = .now
    }

    /// Legacy compatibility wrapper forwarding to performAppLaunchMaintenance.
    func performLaunchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) async {
        await performAppLaunchMaintenance(store: store, preferences: preferences, privacy: privacy)
    }

    /// Performs book-specific reconciliation when switching active ledgers.
    /// This is synchronous/fast and is never blocked by global app-launch maintenance.
    func performLedgerSwitchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore
    ) {
        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)
        store.reconcileSharedActivePurchases()
        store.processDueRecurring()
        store.refreshDueInstallments()
        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)
    }

    /// Performs foreground-transition maintenance operations with in-flight deduplication.
    func performForegroundMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) {
        performLedgerSwitchMaintenance(store: store, preferences: preferences)

        guard !isPerformingBackgroundMaintenance else { return }
        isPerformingBackgroundMaintenance = true

        Task { @MainActor in
            defer { self.isPerformingBackgroundMaintenance = false }
            await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
            await CloudLedgerService.shared.recoverSyncIfNeeded()
            _ = try? await store.refreshExchangeRatesIfNeeded()
            await StockQuoteRefreshService.shared.refreshIfDue(store: store)
            MarketRefreshBackground.schedule(store: store)
            await FinsyNotificationScheduler.shared.reconcileAll(state: store.state, preferences: preferences.value)
            self.lastMaintenanceDate = .now
        }
    }
}
