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

    func latest() async throws -> Result {
        var components = URLComponents(string: "https://api.frankfurter.dev/v2/rates")!
        let quotes = CurrencyCode.allCases.filter { $0 != .HKD }.map(\.rawValue).joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "base", value: "HKD"), URLQueryItem(name: "quotes", value: quotes)]
        guard let url = components.url else { throw RateServiceError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw RateServiceError.server }
        let records = try JSONDecoder().decode([RateRecord].self, from: data)
        var converted: [CurrencyCode: Double] = [.HKD: 1]
        for record in records where record.base.uppercased() == "HKD" && record.rate.isFinite && record.rate > 0 {
            guard let currency = CurrencyCode(rawValue: record.quote.uppercased()), currency != .HKD else { continue }
            converted[currency] = 1 / record.rate
        }
        guard CurrencyCode.allCases.allSatisfy({ converted[$0] != nil }) else { throw RateServiceError.incomplete }
        return Result(rates: converted, sourceDate: records.first?.date ?? "")
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
