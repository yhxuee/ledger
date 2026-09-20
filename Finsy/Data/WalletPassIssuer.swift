import Foundation
import PassKit

public protocol WalletPassIssuer: Sendable {
    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass
    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass
    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass
}

public final class NetworkWalletPassIssuer: WalletPassIssuer {
    private let signingEndpoint: URL?
    private let session: URLSession

    public init(signingEndpoint: URL? = nil, session: URLSession = .shared) {
        self.signingEndpoint = signingEndpoint
        self.session = session
    }

    public func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass {
        try await requestPass(endpointSuffix: "account", payload: snapshot)
    }

    public func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass {
        try await requestPass(endpointSuffix: "purchase-receipt", payload: snapshot)
    }

    public func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass {
        try await requestPass(endpointSuffix: "tax-receipt", payload: snapshot)
    }

    private func requestPass<T: Encodable>(endpointSuffix: String, payload: T) async throws -> PKPass {
        guard let base = signingEndpoint else {
            throw WalletPassError.signingServiceUnavailable("Apple Wallet pass signing requires a configured server-side endpoint. Server-side signing ensures private signing keys never reside on client devices.")
        }
        let url = base.appendingPathComponent(endpointSuffix)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.apple.pkpass", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WalletPassError.signingServiceUnavailable("Signing server returned an unexpected response.")
        }
        do {
            let pass = try PKPass(data: data)
            return pass
        } catch {
            throw WalletPassError.invalidPassData
        }
    }
}

#if DEBUG
public final class MockWalletPassIssuer: WalletPassIssuer, @unchecked Sendable {
    public var mockPassToReturn: PKPass?
    public var lastAccountSnapshot: AccountPassSnapshot?
    public var lastPurchaseSnapshot: PurchaseReceiptPassSnapshot?
    public var lastTaxSnapshot: TaxReceiptPassSnapshot?

    public init(mockPassToReturn: PKPass? = nil) {
        self.mockPassToReturn = mockPassToReturn
    }

    public func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass {
        lastAccountSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }

    public func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass {
        lastPurchaseSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }

    public func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass {
        lastTaxSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }
}
#endif
