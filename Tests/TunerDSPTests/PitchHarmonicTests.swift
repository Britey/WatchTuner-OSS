import XCTest
@testable import TunerDSP

final class PitchHarmonicTests: XCTestCase {
    private let detector = PitchDetector()
    private func signal(_ hz: Double, rate: Double = 48000, fundamental: Double,
                        dominant: Int = 2, gain: Double = 0.3, phase: Double = 0, dominantPhase: Double = 0.37,
                        third: Double = 0, noise: Double = 0) -> [Float] {
        var seed: UInt64 = 123
        return (0..<Int(rate * 0.18)).map { i in
            let p = 2 * Double.pi * hz * Double(i) / rate
            seed = seed &* 6364136223846793005 &+ 1
            let random = Double(seed >> 32) / Double(UInt32.max) - 0.5
            return Float(fundamental * sin(p + phase) + gain * sin(Double(dominant) * p + dominantPhase)
                         + third * sin(3 * p - 0.2) + noise * random)
        }
    }
    private func expect(_ samples: [Float], rate: Double, hz: Double,
                        context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case let .pitch(actual, confidence) = detector.analyze(samples, sampleRate: rate) else {
            return XCTFail("No pitch for \(hz) Hz @ \(rate) \(context)", file: file, line: line)
        }
        XCTAssertLessThan(abs(1200 * log2(actual / hz)), 4, "\(hz) → \(actual) @ \(rate) \(context)", file: file, line: line)
        XCTAssertGreaterThan(confidence, 0.85, file: file, line: line)
    }
    func testReviewerDominantSecondHarmonic() {
        for hz in [55.0, 82.4069, 146.832, 440, 880, 1760] {
            expect(signal(hz, fundamental: 0.06, dominantPhase: 0), rate: 48000, hz: hz)
        }
    }
    func testDominantHarmonicMatrixAcrossLevelsPhasesAndRates() {
        for rate in [16000.0, 44100, 48000] {
            for hz in [55.0, 110, 440, 880, 1760, 1987] {
                for harmonic in [2, 3, 4] where hz * Double(harmonic) < rate * 0.45 {
                    for ratio in [0.05, 0.1, 0.2, 0.4] {
                        for scale in [0.2, 1.0] {
                            for phase in [0.0, 1.17, 2.4] {
                                let input = signal(hz, rate: rate, fundamental: 0.3 * ratio * scale,
                                                   dominant: harmonic, gain: 0.3 * scale, phase: phase)
                                let context = "harmonic=\(harmonic) ratio=\(ratio) scale=\(scale) phase=\(phase)"
                                if harmonic == 2 {
                                    // Dominant-second review cases must resolve, even at 20:1.
                                    expect(input, rate: rate, hz: hz, context: context)
                                } else {
                                    // Higher-harmonic ambiguity may be rejected, never guessed as
                                    // a confident octave/subharmonic. Correct pitches remain strict.
                                    let reading = detector.analyze(input, sampleRate: rate)
                                    if case .pitch = reading { expect(input, rate: rate, hz: hz, context: context) }
                                    else { XCTAssertEqual(reading, .unclear, context) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func testPureToneGridNeverAcquiresSubharmonic() {
        for rate in [8000.0, 16000, 44100, 48000] {
            for hz in stride(from: 55.0, through: 2000.0, by: 37.17) {
                expect(signal(hz, rate: rate, fundamental: 0.3, gain: 0, phase: 0.71), rate: rate, hz: hz)
            }
        }
    }
    func testMissingFundamentalAndSecondOnlyAreDistinct() {
        for hz in [55.0, 146.832, 440, 880] {
            expect(signal(hz, fundamental: 0, third: 0.15), rate: 48000, hz: hz)
            expect(signal(hz, fundamental: 0), rate: 48000, hz: hz * 2)
        }
    }
    func testOutOfRangePureTonesAreNotFoldedIntoRange() {
        for hz in [25.0, 40, 2100, 3520, 4000, 7040] {
            XCTAssertEqual(detector.analyze(signal(hz, fundamental: 0.3, gain: 0), sampleRate: 48000), .unclear, "\(hz)")
        }
    }
    func testFundamentalBelowRangeIsRejectedRatherThanItsLouderHarmonic() {
        for hz in [25.0, 40, 50] {
            for harmonic in [2, 3, 4] {
                XCTAssertEqual(detector.analyze(signal(hz, fundamental: 0.06, dominant: harmonic), sampleRate: 48000), .unclear)
            }
        }
    }
    func testDominantSecondWithNoiseAndInvalidRate() {
        for hz in [82.4069, 220, 440, 1760] {
            expect(signal(hz, fundamental: 0.06, noise: 0.02), rate: 48000, hz: hz)
        }
        XCTAssertEqual(detector.analyze([Float](repeating: 0.2, count: 1000), sampleRate: .greatestFiniteMagnitude), .unclear)
    }
}
