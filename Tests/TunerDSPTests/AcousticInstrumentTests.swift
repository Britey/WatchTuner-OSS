import XCTest
@testable import TunerDSP

/// Historical noise-aware harmonic-detector tests, not the shipped app path.
/// Generated acoustic approximations, not recordings or a substitute for Watch tests.
final class AcousticInstrumentTests: XCTestCase {
    private func instrument(hz: Double, rate: Double, amplitude: Double, piano: Bool,
                            noise: Double = 0.15, offset: Double = 0.2) -> [Float] {
        var state: UInt64 = 193939
        let detunings = piano ? [-2.5, 0, 2.5] : [0.0]
        return (0..<Int(rate * 0.18)).map { index in
            let t = Double(index) / rate + offset
            state = state &* 6364136223846793005 &+ 1
            var value = noise * (Double(state >> 32) / Double(UInt32.max) * 2 - 1)
            for cents in detunings {
                for harmonic in 1...10 {
                    let h = Double(harmonic)
                    let frequency = hz * pow(2, cents / 1200) * h * sqrt((1 + 0.0002 * h*h) / 1.0002)
                    guard frequency < rate * 0.45 else { continue }
                    let envelope = exp(-t / (0.8 / sqrt(h)))
                    let phase = 2 * Double.pi * frequency * t + 0.31 * h + cents
                    // A direct path plus a fixed, attenuated room reflection.
                    value += envelope / (h * Double(detunings.count)) * (sin(phase) + 0.35 * sin(phase - 2 * .pi * frequency * 0.013))
                }
            }
            return Float(amplitude * value)
        }
    }
    func testQuietDecayingInstrumentWithRoomNoise() {
        for profile in [TunerProfile.piano, .guitar] {
            for rate in [16000.0, 48000] {
                for hz in [110.0, 220, 440, 880] {
                    for amplitude in [0.1, 0.00003] {
                        let input = instrument(hz: hz, rate: rate, amplitude: amplitude, piano: profile == .piano)
                        let result = PitchDetector(profile: profile, noiseAware: true).analyze(input, sampleRate: rate)
                        guard case let .pitch(actual, _) = result else {
                            XCTFail("\(profile) rate=\(rate) hz=\(hz) amp=\(amplitude): \(result)"); continue
                        }
                        XCTAssertLessThan(abs(1200 * log2(actual / hz)), 8)
                    }
                }
            }
        }
    }
    func testMarginalPianoSignalsMayClearButNeverInventANote() {
        var reports = 0
        for rate in [16000.0, 48000] {
            for hz in [110.0, 220, 440, 880] {
                let result = PitchDetector(profile: .piano, noiseAware: true).analyze(instrument(hz: hz, rate: rate, amplitude: 0.00003, piano: true, noise: 0.25), sampleRate: rate)
                if case let .pitch(actual, _) = result {
                    reports += 1
                    XCTAssertLessThan(abs(1200 * log2(actual / hz)), 8)
                } else { XCTAssertEqual(result, .unclear) }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 6)
    }
    func testInstrumentProfilesRejectNoiseAndUnrelatedNotes() {
        for profile in [TunerProfile.piano, .guitar] {
            for seed in 1...32 {
                var state = UInt64(seed), low = 0.0
                let input: [Float] = (0..<8640).map { _ in
                    state = state &* 6364136223846793005 &+ 1
                    let white = Double(state >> 32) / Double(UInt32.max) * 2 - 1
                    low = 0.92 * low + 0.08 * white
                    return Float((seed % 2 == 0 ? white : low) * 0.00003)
                }
                XCTAssertEqual(PitchDetector(profile: profile, noiseAware: true).analyze(input, sampleRate: 48000), .unclear)
            }
            for ratio in [sqrt(2.0), sqrt(3.0), pow(2, 4.0/12)] {
                let input: [Float] = (0..<8640).map {
                    Float(0.1 * sin(2 * .pi * 440 * Double($0)/48000) + 0.08 * sin(2 * .pi * 440 * ratio * Double($0)/48000))
                }
                XCTAssertEqual(PitchDetector(profile: profile, noiseAware: true).analyze(input, sampleRate: 48000), .unclear)
            }
        }
    }

}
