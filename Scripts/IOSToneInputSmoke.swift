import Foundation

@main
struct IOSToneInputSmoke {
    static func main() {
        var checks = 0
        for identifier in ["en_US", "fr_FR", "de_DE", "ar_EG", "fa_IR", "bn_BD"] {
            let locale = Locale(identifier: identifier)
            for hz in [20.0, 440, 440.5, 7999.25, 8000] {
                let text = ToneFrequencyInput.text(for: hz, locale: locale)
                precondition(ToneFrequencyInput.frequency(from: text, locale: locale) == hz,
                             "Cannot play app-formatted frequency in \(identifier): \(text)")
                checks += 1
            }
        }
        for text in ["19.99", "8000.01", "nan", "inf", "440junk", "440,1,2", "", "-440"] {
            precondition(ToneFrequencyInput.frequency(from: text, locale: Locale(identifier: "en_US")) == nil,
                         "Invalid tone input accepted: \(text)")
            checks += 1
        }
        precondition(ToneFrequencyInput.frequency(from: " ٤٤٠٫٥ ", locale: Locale(identifier: "ar_EG")) == 440.5)
        precondition(ToneFrequencyInput.frequency(from: "440,5", locale: Locale(identifier: "fr_FR")) == 440.5)
        print("PASS: \(checks + 2) tone-input checks; locale round-trips, Unicode digits, decimal separators, invalid/range rejection")
    }
}
