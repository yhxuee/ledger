import Foundation

/// Centralized sanitizer and validator for Finsy Account Tags.
///
/// Account Tags must consist of at most 6 uppercase ASCII English letters (A–Z).
/// Digits, spaces, punctuation, emoji, and non-ASCII characters are stripped silently.
enum AccountTag {
    static let maxLength: Int = 6

    static func sanitize(_ value: String) -> String {
        let filtered = value
            .uppercased()
            .filter { $0.isASCII && $0.isLetter }
        return String(filtered.prefix(maxLength))
    }
}
