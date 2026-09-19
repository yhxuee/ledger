import Foundation

enum PurchaseSessionStatus: String, Codable, CaseIterable, Sendable {
    case draft, active, awaitingSummary, completed, cancelled
}

struct PurchaseCategorySection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var categoryID: LedgerCategoryID
    var displayOrder: Int
}

struct PurchaseItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var categoryID: LedgerCategoryID
    var note: String
    var amount: Double
    var displayOrder: Int
    var isCompleted: Bool
    var completedAt: Date?
    /// Legacy decoding only; payment is owned by PurchaseSession.
    var resolvedAccountID: UUID? = nil
    var linkedTransactionID: UUID?
}

struct PurchaseSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ledgerBookID: UUID
    var name: String
    var status: PurchaseSessionStatus
    var sections: [PurchaseCategorySection]
    var items: [PurchaseItem]
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var receiptAttachmentID: String?
    var currency: CurrencyCode = .HKD
    var accountID: UUID? = nil
    var updatedAt: Date? = nil
    var requiresCurrencyMigration = false
    var requiresPaymentMigration = false

    enum CodingKeys: String, CodingKey {
        case id, ledgerBookID, name, status, sections, items, createdAt, startedAt, completedAt, receiptAttachmentID
        case currency, accountID, updatedAt
    }

    var orderedSections: [PurchaseCategorySection] {
        sections.filter { section in items.contains { $0.categoryID == section.categoryID } }.sorted {
            $0.displayOrder == $1.displayOrder ? $0.categoryID.rawValue < $1.categoryID.rawValue : $0.displayOrder < $1.displayOrder
        }
    }
    var orderedItems: [PurchaseItem] {
        let order = Dictionary(orderedSections.enumerated().map { ($0.element.categoryID, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return items.sorted {
            let lhs = order[$0.categoryID] ?? Int.max, rhs = order[$1.categoryID] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var plannedAmount: Double { items.reduce(0) { $0 + $1.amount } }
    var completedAmount: Double { items.filter(\.isCompleted).reduce(0) { $0 + $1.amount } }
    var completedItemCount: Int { items.filter(\.isCompleted).count }
    var completionFraction: Double { items.isEmpty ? 0 : Double(completedItemCount) / Double(items.count) }

    mutating func normalizeSections() {
        var unique = Set<LedgerCategoryID>()
        sections = orderedSections.filter { unique.insert($0.categoryID).inserted }
        for item in items.sorted(by: { $0.displayOrder == $1.displayOrder ? $0.id.uuidString < $1.id.uuidString : $0.displayOrder < $1.displayOrder }) {
            if unique.insert(item.categoryID).inserted {
                sections.append(.init(id: UUID(), categoryID: item.categoryID, displayOrder: sections.count))
            }
        }
        for index in sections.indices { sections[index].displayOrder = index }
    }
}

extension PurchaseSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ledgerBookID = try c.decode(UUID.self, forKey: .ledgerBookID)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(PurchaseSessionStatus.self, forKey: .status)
        sections = try c.decode([PurchaseCategorySection].self, forKey: .sections)
        items = try c.decode([PurchaseItem].self, forKey: .items)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        receiptAttachmentID = try c.decodeIfPresent(String.self, forKey: .receiptAttachmentID)
        currency = try c.decodeIfPresent(CurrencyCode.self, forKey: .currency) ?? .HKD
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        requiresCurrencyMigration = !c.contains(.currency)
        requiresPaymentMigration = !c.contains(.currency) && !c.contains(.accountID)
    }
}
