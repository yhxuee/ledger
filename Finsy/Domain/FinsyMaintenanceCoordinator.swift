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

    private var ledgerSwitchTask: Task<Void, Never>?

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
        await CloudLedgerService.shared.recoverSyncIfNeeded()
        await ICloudSyncCoordinator.shared.maintenance(store: store, preferences: preferences)
        await ICloudLibraryCoordinator.shared.maintenance(store: store, preferences: preferences)
        RecentTransactionActivityCoordinator.shared.registerObservers(store: store)

        // Perform initial book-specific reconciliation
        scheduleLedgerSwitchMaintenance(store: store, preferences: preferences, expectedBookID: store.activeBookID)

        _ = try? await store.refreshCurrencyCatalogIfNeeded()
        _ = try? await store.refreshExchangeRatesIfNeeded()
        await StockQuoteRefreshService.shared.refreshIfDue(store: store)
        MarketRefreshBackground.schedule(store: store)
        await FinsyNotificationScheduler.shared.reconcileGlobalReminders(preferences: preferences.value)
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

    /// Schedules book-specific reconciliation when switching active ledgers.
    /// Serializes execution so that in-flight tasks complete/cancel before a new reconciliation begins,
    /// guaranteeing that the newest active ledger deterministically wins without race conditions.
    func scheduleLedgerSwitchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        expectedBookID: UUID
    ) {
        let previousTask = ledgerSwitchTask
        previousTask?.cancel()

        let nextTask = Task { @MainActor in
            if let previousTask {
                _ = await previousTask.result
            }

            guard !Task.isCancelled,
                  store.activeBookID == expectedBookID else {
                return
            }

            await performLedgerSwitchMaintenance(
                store: store,
                preferences: preferences,
                expectedBookID: expectedBookID
            )
        }

        ledgerSwitchTask = nextTask
    }

    /// Performs book-specific reconciliation when switching active ledgers.
    /// Reconciles recent actions, active purchases, recurring rules, installments, widget snapshots,
    /// and coupon reminder notifications.
    func performLedgerSwitchMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        expectedBookID: UUID
    ) async {
        guard !Task.isCancelled, store.activeBookID == expectedBookID else { return }

        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)
        store.reconcileSharedActivePurchases()
        store.processDueRecurring()
        store.refreshDueInstallments()
        OverviewWidgetRelay.updateSnapshot(store: store, preferences: preferences.value)

        guard !Task.isCancelled, store.activeBookID == expectedBookID else { return }

        await FinsyNotificationScheduler.shared.reconcileCouponReminders(accounts: store.state.accounts)

        guard !Task.isCancelled, store.activeBookID == expectedBookID else { return }
    }

    /// Performs foreground-transition maintenance operations with in-flight deduplication.
    func performForegroundMaintenance(
        store: LedgerStore,
        preferences: AppPreferencesStore,
        privacy: PrivacyController
    ) {
        scheduleLedgerSwitchMaintenance(store: store, preferences: preferences, expectedBookID: store.activeBookID)

        // Unlocking must not wait for an earlier sync or backup to finish.
        Task { @MainActor in
            await privacy.unlockIfNeeded(protectionEnabled: preferences.value.biometricLockEnabled)
        }
        guard !isPerformingBackgroundMaintenance else { return }
        isPerformingBackgroundMaintenance = true

        Task { @MainActor in
            defer { self.isPerformingBackgroundMaintenance = false }
            await CloudLedgerService.shared.recoverSyncIfNeeded()
            await ICloudSyncCoordinator.shared.maintenance(store: store, preferences: preferences)
            await ICloudLibraryCoordinator.shared.maintenance(store: store, preferences: preferences)
            _ = try? await store.refreshExchangeRatesIfNeeded()
            await StockQuoteRefreshService.shared.refreshIfDue(store: store)
            MarketRefreshBackground.schedule(store: store)
            await FinsyNotificationScheduler.shared.reconcileGlobalReminders(preferences: preferences.value)
            self.lastMaintenanceDate = .now
        }
    }
}
