import Foundation

struct CurrencyCode: RawRepresentable, Codable, Hashable, Identifiable, Sendable, CaseIterable, CodingKeyRepresentable {
    let rawValue: String
    var id: String { rawValue }

    private static let supportedCodes = "AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CMD CNH CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GGP GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS IMP INR IQD IRR ISK JEP JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRO MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES VND VUV WST XAF XAG XAU XCD XCG XDR XOF XPD XPF XPT YER ZAR ZMW ZWG"
    static let allCases = supportedCodes.split(separator: " ").map { CurrencyCode(unchecked: String($0)) } + usdStablecoins
    static let USDT = CurrencyCode(unchecked: "USDT")
    static let USDC = CurrencyCode(unchecked: "USDC")
    static let PYUSD = CurrencyCode(unchecked: "PYUSD")
    static let BUSD = CurrencyCode(unchecked: "BUSD")
    static let GUSD = CurrencyCode(unchecked: "GUSD")
    static let usdStablecoins: [CurrencyCode] = [.USDT, .USDC, .PYUSD, .BUSD, .GUSD]
    static let preferredFiat = ["HKD", "USD", "GBP", "JPY", "CNY", "EUR", "SGD", "CHF"].map { CurrencyCode(unchecked: $0) }
    var isUSDStablecoin: Bool { Self.usdStablecoins.contains(self) }
    var referenceCurrency: CurrencyCode { isUSDStablecoin ? .USD : self }
    var stablecoinName: String? {
        switch rawValue {
        case "USDT": "Tether USD"
        case "USDC": "USD Coin"
        case "PYUSD": "PayPal USD"
        case "BUSD": "Binance USD"
        case "GUSD": "Gemini Dollar"
        default: nil
        }
    }

    static let HKD = CurrencyCode(unchecked: "HKD")
    static let USD = CurrencyCode(unchecked: "USD")
    static let CNY = CurrencyCode(unchecked: "CNY")
    static let MYR = CurrencyCode(unchecked: "MYR")
    static let EUR = CurrencyCode(unchecked: "EUR")
    static let GBP = CurrencyCode(unchecked: "GBP")
    static let JPY = CurrencyCode(unchecked: "JPY")
    static let SGD = CurrencyCode(unchecked: "SGD")
    static let CHF = CurrencyCode(unchecked: "CHF")

    init?(rawValue: String) {
        let normalized = rawValue.uppercased()
        let isFiatCode = normalized.utf8.count == 3 && normalized.utf8.allSatisfy { (65...90).contains($0) }
        guard isFiatCode || Self.usdStablecoins.contains(where: { $0.rawValue == normalized }) else { return nil }
        self.rawValue = normalized
    }

    private init(unchecked rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let currency = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported currency code: \(value)")
        }
        self = currency
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    var name: String { stablecoinName ?? rawValue }
    var symbol: String {
        // USD-pegged stablecoins display the dollar symbol in normal monetary amounts
        // while keeping their own identifier everywhere else.
        if isUSDStablecoin { return "$" }
        switch rawValue {
        case "HKD", "USD", "AUD", "CAD", "NZD", "SGD", "TWD": return "$"
        case "CNY", "JPY": return "¥"
        case "MYR": return "RM"
        case "EUR": return "€"
        case "GBP": return "£"
        case "KRW": return "₩"
        case "INR": return "₹"
        case "THB": return "฿"
        default: return rawValue
        }
    }
}

struct CurrencyDescriptor: Identifiable, Codable, Hashable, Sendable {
    var code: CurrencyCode
    var name: String
    var symbol: String?
    var id: CurrencyCode { code }

    static var bundled: [CurrencyDescriptor] {
        CurrencyCode.allCases.map { .init(code: $0, name: $0.name, symbol: $0.symbol == $0.rawValue ? nil : $0.symbol) }
    }

    static func appCatalog(_ fetched: [CurrencyDescriptor]) -> [CurrencyDescriptor] {
        let codes = Set(bundled.map(\.code) + fetched.map(\.code))
        return codes.sorted { $0.rawValue < $1.rawValue }.map {
            .init(code: $0, name: $0.name, symbol: $0.symbol)
        }
    }
}

struct LedgerCategoryID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    static let food = Self(rawValue: "food")
    static let transport = Self(rawValue: "transport")
    static let shopping = Self(rawValue: "shopping")
    static let utilities = Self(rawValue: "utilities")
    static let other = Self(rawValue: "other")
    static let builtIns: [Self] = [.food, .transport, .shopping, .utilities, .other]
}

enum SyncStatus: String, Codable, Sendable { case synced, pending, conflict }
