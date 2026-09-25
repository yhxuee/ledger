import Foundation
import PassKit

public struct WalletPassConfiguration: Sendable {
    public static let issuerURLKey = "FINSY_WALLET_PASS_ISSUER_URL"

    public static var issuerURL: URL? {
        if let envString = ProcessInfo.processInfo.environment[issuerURLKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = validIssuerURL(envString) {
            return url
        }
        if let bundleString = Bundle.main.object(forInfoDictionaryKey: issuerURLKey) as? String,
           let url = validIssuerURL(bundleString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return nil
    }

    private static func validIssuerURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }
}

protocol WalletPassIssuer: Sendable {
    var isConfigured: Bool { get }
    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass
    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass
    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass
}

final class NetworkWalletPassIssuer: WalletPassIssuer {
    let signingEndpoint: URL?
    private let session: URLSession

    var isConfigured: Bool {
        signingEndpoint?.scheme?.lowercased() == "https" && signingEndpoint?.host != nil
    }

    init(signingEndpoint: URL? = WalletPassConfiguration.issuerURL, session: URLSession = .shared) {
        self.signingEndpoint = signingEndpoint
        self.session = session
    }

    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass {
        try await requestPass(endpointSuffix: "account", payload: snapshot)
    }

    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass {
        try await requestPass(endpointSuffix: "purchase-receipt", payload: snapshot)
    }

    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass {
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
final class MockWalletPassIssuer: WalletPassIssuer, @unchecked Sendable {
    var isConfigured: Bool = true
    var mockPassToReturn: PKPass?
    var lastAccountSnapshot: AccountPassSnapshot?
    var lastPurchaseSnapshot: PurchaseReceiptPassSnapshot?
    var lastTaxSnapshot: TaxReceiptPassSnapshot?

    init(mockPassToReturn: PKPass? = nil) {
        self.mockPassToReturn = mockPassToReturn
    }

    func issueAccountPass(snapshot: AccountPassSnapshot) async throws -> PKPass {
        lastAccountSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }

    func issuePurchaseReceiptPass(snapshot: PurchaseReceiptPassSnapshot) async throws -> PKPass {
        lastPurchaseSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }

    func issueTaxReceiptPass(snapshot: TaxReceiptPassSnapshot) async throws -> PKPass {
        lastTaxSnapshot = snapshot
        if let pass = mockPassToReturn { return pass }
        throw WalletPassError.signingServiceUnavailable("Mock pass not configured.")
    }
}
#endif
