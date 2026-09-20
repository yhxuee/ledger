import Foundation

actor FrankfurterRateService {
    static let shared = FrankfurterRateService()

    struct Result: Sendable {
        let rates: [CurrencyCode: Double]
        let sourceDate: String
    }

    private struct RateRecord: Decodable {
        let date: String
        let base: String
        let quote: String
        let rate: Double
    }

    private struct CurrencyRecord: Decodable {
        let isoCode: String
        let name: String
        let symbol: String?
    }

    func currencyCatalog() async throws -> [CurrencyDescriptor] {
        guard let url = URL(string: "https://api.frankfurter.dev/v2/currencies") else { throw RateServiceError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw RateServiceError.server }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let records = try decoder.decode([CurrencyRecord].self, from: data)
        let currencies = records.compactMap { record -> CurrencyDescriptor? in
            guard let code = CurrencyCode(rawValue: record.isoCode) else { return nil }
            return .init(code: code, name: record.name, symbol: record.symbol)
        }
        guard !currencies.isEmpty else { throw RateServiceError.incomplete }
        return currencies.sorted { $0.code.rawValue < $1.code.rawValue }
    }

    func latest() async throws -> Result {
        var components = URLComponents(string: "https://api.frankfurter.dev/v2/rates")!
        components.queryItems = [URLQueryItem(name: "base", value: "HKD")]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw RateServiceError.server }
        let records = try JSONDecoder().decode([RateRecord].self, from: data)
        var converted: [CurrencyCode: Double] = [.HKD: 1]
        for record in records where record.base.uppercased() == "HKD" && record.rate.isFinite && record.rate > 0 {
            guard let currency = CurrencyCode(rawValue: record.quote), currency != .HKD else { continue }
            converted[currency] = 1 / record.rate
        }
        guard [.USD, .CNY, .EUR, .GBP, .JPY].allSatisfy({ converted[$0] != nil }) else { throw RateServiceError.incomplete }
        return Result(rates: converted, sourceDate: records.map(\.date).max() ?? "")
    }
}

enum RateServiceError: LocalizedError {
    case invalidURL, server, incomplete
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Could not create the Frankfurter request."
        case .server: "Frankfurter did not return a successful response."
        case .incomplete: "Frankfurter returned an incomplete currency set."
        }
    }
}
