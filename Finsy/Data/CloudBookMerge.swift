import Foundation

enum CloudBookMerge {
    static func merge(local: LedgerBook, remote: LedgerBook, deletedRecordNames: Set<String> = []) throws -> LedgerBook {
        guard local.id == remote.id else { throw BackupError.invalidFormat }
        // A locked placeholder contains no usable state. Never replace a real local ledger with it.
        if remote.effectiveEncryptionState == .authorizationRequired {
            var locked = remote
            locked.state = local.state
            return locked
        }
        if local.effectiveEncryptionState == .authorizationRequired && local.state.accounts.isEmpty && local.state.transactions.isEmpty { return remote }
        var result = remote.updatedAt >= local.updatedAt ? remote : local
        result.cloudZoneName = remote.cloudZoneName
        result.cloudZoneOwnerName = remote.cloudZoneOwnerName
        result.storageKind = remote.storageKind
        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        // Financial edits must not implicitly turn encryption on or off. Track the
        // configuration independently, and always follow the owner on participant devices.
        let remoteSecurityWins = local.effectiveEncryptionState == .authorizationRequired || remote.effectiveStorageKind == .cloudParticipant
            || (remote.encryptionUpdatedAt ?? .distantPast) > (local.encryptionUpdatedAt ?? .distantPast)
            || (remote.encryptionUpdatedAt == nil && local.encryptionUpdatedAt == nil && remote.isEncrypted == true)
        let security = remoteSecurityWins ? remote : local
        result.isEncrypted = security.isEncrypted
        result.encryptionState = security.encryptionState
        result.encryptionVersion = security.encryptionVersion
        result.keyFingerprint = security.keyFingerprint
        result.encryptionUpdatedAt = security.encryptionUpdatedAt
        func mergeValues<T: Identifiable>(_ lhs: [T], _ rhs: [T], prefix: String, version: (T) -> Int = { _ in 0 }, date: (T) -> Date) throws -> [T] where T.ID: Hashable {
            guard Set(lhs.map(\.id)).count == lhs.count, Set(rhs.map(\.id)).count == rhs.count else {
                throw PersistenceIntegrityError.duplicateID("\(prefix) merge")
            }
            let incoming = Dictionary(rhs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let localIDs = Set(lhs.map(\.id))
            var values = lhs.filter { !deletedRecordNames.contains("\(prefix)-\($0.id)") }.map { value in
                if let replacement = incoming[value.id],
                   version(replacement) > version(value) || (version(replacement) == version(value) && date(replacement) >= date(value)) { return replacement }
                return value
            }
            values += rhs.filter { !localIDs.contains($0.id) && !deletedRecordNames.contains("\(prefix)-\($0.id)") }
            return values
        }
        result.state.accounts = try mergeValues(local.state.accounts, remote.state.accounts, prefix: "account", version: { $0.version }, date: { $0.updatedAt })
        result.state.transactions = try mergeValues(local.state.transactions, remote.state.transactions, prefix: "transaction", version: { $0.version }, date: { $0.updatedAt })
        result.state.recurringRules = try mergeValues(local.state.recurringRules ?? [], remote.state.recurringRules ?? [], prefix: "recurring", date: { $0.updatedAt })
        result.state.purchaseSessions = try mergeValues(local.state.purchaseSessions ?? [], remote.state.purchaseSessions ?? [], prefix: "purchase", date: { $0.updatedAt ?? $0.completedAt ?? $0.startedAt ?? $0.createdAt })
        let remoteSettingsWin = remote.state.settings.updatedAt >= local.state.settings.updatedAt
        result.state.settings = remoteSettingsWin ? remote.state.settings : local.state.settings
        result.state.categories = remoteSettingsWin ? remote.state.categories : local.state.categories
        // Preserve categories referenced by an unsent local transaction.
        let categories = Set(result.state.categories.map(\.id))
        let other = remoteSettingsWin ? local.state.categories : remote.state.categories
        result.state.categories += other.filter { !categories.contains($0.id) }
        SchemaMigration.normalize(&result.state)
        try BackupCodec.validate(result.state)
        return result
    }
}
