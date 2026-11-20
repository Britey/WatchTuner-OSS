import Foundation

/// Keep typed Hz and the app's own displayed text compatible with the user's
/// decimal separator and decimal digits. Grouping is intentionally never emitted.
enum ToneFrequencyInput {
    static func text(for frequency: Double, locale: Locale = .current) -> String {
        frequency.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...2)))
    }

    static func frequency(from text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let decimalNormalized = trimmed.replacingOccurrences(of: separator, with: ".")
            .replacingOccurrences(of: ",", with: ".")
        let normalized = decimalNormalized.map { character -> String in
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                return String(digit)
            }
            return String(character)
        }.joined()
        guard let frequency = Double(normalized), ToneOutputPolicy.permits(frequency) else { return nil }
        return frequency
    }
}
