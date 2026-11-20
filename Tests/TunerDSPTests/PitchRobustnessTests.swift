import XCTest
@testable import TunerDSP

final class PitchRobustnessTests: XCTestCase {
    private let detector = PitchDetector()
    @discardableResult private func valid(_ reading: PitchReading, hz: Double, tolerance: Double = 4,
                                          file: StaticString = #filePath, line: UInt = #line) -> Bool {
        switch reading {
        case let .pitch(actual, _):
            XCTAssertLessThan(abs(1200 * log2(actual / hz)), tolerance, "\(hz) → \(actual)", file: file, line: line)
            return true
        case .unclear: return false
        default: XCTFail("Unexpected \(reading)", file: file, line: line); return false
        }
    }
    func testDominantFifthThroughEighthHarmonics() {
        for rate in [16000.0, 44100, 48000] {
            for hz in [55.0, 110, 220, 440, 880, 1760] {
                for harmonic in 5...8 where hz * Double(harmonic) < rate * 0.45 {
                    for ratio in [0.05, 0.2, 0.4] {
                        let input: [Float] = (0..<Int(rate * 0.18)).map { i in
                            let p = 2 * Double.pi * hz * Double(i) / rate
                            return Float(0.3 * ratio * sin(p + 0.83) + 0.3 * sin(Double(harmonic) * p - 0.37))
                        }
                        let resolved = valid(detector.analyze(input, sampleRate: rate), hz: hz)
                        if hz * Double(harmonic) < rate * 0.2 { XCTAssertTrue(resolved) }
                    }
                }
            }
        }
    }
    func testDecayingSignalsResolveOrRejectWithoutWrongOctaves() {
        var reports = 0
        for hz in [82.4069, 220, 440, 1760] {
            for decay in [0.08, 0.3, 1.0] {
                let input: [Float] = (0..<8640).map { i in
                    let time = Double(i) / 48000
                    let p = 2 * Double.pi * hz * time
                    return Float(exp(-time / decay) * (0.15 * sin(p) + 0.3 * sin(2*p + 0.71)))
                }
                let resolved = valid(detector.analyze(input, sampleRate: 48000), hz: hz)
                if resolved { reports += 1 }
                if decay >= 0.3 { XCTAssertTrue(resolved) }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 8)
    }
    func testVibratoStaysInsideItsFrequencyBandOrRejects() {
        var reports = 0
        for hz in [82.4069, 220, 440, 880] {
            for depth in [5.0, 20, 50] {
                var phase = 0.0
                let input: [Float] = (0..<8640).map { i in
                    let time = Double(i) / 48000
                    let instantaneous = hz * pow(2, depth * sin(2 * .pi * 5 * time) / 1200)
                    phase += 2 * .pi * instantaneous / 48000
                    return Float(0.2 * sin(phase) + 0.12 * sin(2 * phase))
                }
                if valid(detector.analyze(input, sampleRate: 48000), hz: hz, tolerance: depth + 3) { reports += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 6)
    }
    func testSignificantInharmonicPartialsAreAmbiguous() {
        for hz in [110.0, 440, 880] {
            for stretch in [1.01, 1.03] {
                let input: [Float] = (0..<8640).map { i in
                    let p = 2 * Double.pi * hz * Double(i) / 48000
                    return Float(0.1 * sin(p) + 0.3 * sin(2 * p * stretch) + 0.1 * sin(3 * p))
                }
                XCTAssertEqual(detector.analyze(input, sampleRate: 48000), .unclear)
            }
        }
    }
}
