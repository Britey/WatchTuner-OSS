import Foundation

public struct MusicalNote: Equatable, Sendable {
    public let midi: Int
    public let referenceHz: Double
    public let cents: Double
    public var name: String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[((midi % 12) + 12) % 12])\(Int(floor(Double(midi) / 12)) - 1)"
    }
    public init?(frequency: Double) {
        guard frequency.isFinite, (1...100_000).contains(frequency) else { return nil }
        let position = 69 + 12 * log2(frequency / 440)
        midi = Int(position.rounded())
        referenceHz = 440 * pow(2, Double(midi - 69) / 12)
        cents = 1200 * log2(frequency / referenceHz)
    }
}
