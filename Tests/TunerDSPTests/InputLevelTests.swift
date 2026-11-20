import XCTest
import Dispatch
@testable import TunerDSP

private final class LevelReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PitchReading] = []
    func add(_ value: PitchReading) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [PitchReading] { lock.lock(); defer { lock.unlock() }; return values }
}

final class InputLevelTests: XCTestCase {
    private func tone(_ hz: Double, amplitude: Double, rate: Double = 48000,
                      dc: Double = 0, noiseRatio: Double = 0) -> [Float] {
        var seed: UInt64 = 197683
        return (0..<Int(rate * 0.18)).map { i in
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
            return Float(dc + amplitude * (sin(2 * .pi * hz * Double(i) / rate) + noiseRatio * noise))
        }
    }
    private func expectPitch(_ input: [Float], profile: TunerProfile, rate: Double = 48000,
                             hz: Double, file: StaticString = #filePath, line: UInt = #line) {
        let reading = PitchDetector(profile: profile).analyze(input, sampleRate: rate)
        guard case let .pitch(actual, confidence) = reading else {
            return XCTFail("\(profile) expected \(hz), got \(reading)", file: file, line: line)
        }
        XCTAssertLessThan(abs(1200 * log2(actual / hz)), 2, file: file, line: line)
        XCTAssertGreaterThan(confidence, 0.85, file: file, line: line)
    }
    func testQuietAndNearFullScaleTonesAcrossProfilesAndRates() {
        for profile in TunerProfile.allCases {
            for rate in [16000.0, 44100, 48000] {
                for amplitude in [0.995, 0.2, 0.005, 0.001, 0.0001, 0.00001, 0.000003] {
                    for hz in [110.0, 440, 997.3] {
                        expectPitch(tone(hz, amplitude: amplitude, rate: rate), profile: profile, rate: rate, hz: hz)
                    }
                }
            }
        }
    }
    func testQuietSignalWithNoiseAndDCIsLevelInvariant() {
        for profile in TunerProfile.allCases {
            for amplitude in [0.3, 0.003, 0.00003] {
                for hz in [220.0, 440, 880] {
                    expectPitch(tone(hz, amplitude: amplitude, dc: 0.1, noiseRatio: 0.1), profile: profile, hz: hz)
                }
            }
        }
    }
    func testWhiteColoredAndUnvoicedNoiseNeverBecomePitchWhenAmplified() {
        for amplitude in [0.5, 0.005, 0.00005, 0.000003] {
            for seed in 1...8 {
                var state = UInt64(seed), low = 0.0
                var white: [Float] = [], colored: [Float] = []
                for _ in 0..<8640 {
                    state = state &* 6364136223846793005 &+ 1
                    let value = Double(state >> 32) / Double(UInt32.max) * 2 - 1
                    low = 0.92 * low + 0.08 * value
                    white.append(Float(value * amplitude))
                    colored.append(Float(low * amplitude))
                }
                for profile in TunerProfile.allCases {
                    for input in [white, colored] {
                        let reading = PitchDetector(profile: profile).analyze(input, sampleRate: 48000)
                        if case .pitch = reading { XCTFail("Noise became pitch: \(profile), amplitude \(amplitude), seed \(seed)") }
                    }
                }
            }
        }
    }
    func testLevelingRaisesQuietAndAttenuatesLoudWithoutChangingShape() {
        for amplitude in [0.00001, 0.8, 2.0] {
            let input = tone(440, amplitude: amplitude)
            guard case let .ready(samples, inputRMS, gain) = PitchInputLeveling.prepare(input) else {
                return XCTFail("Expected leveled input")
            }
            if amplitude < 0.01 { XCTAssertGreaterThan(gain, 1) }
            else { XCTAssertLessThan(gain, 1) }
            XCTAssertLessThanOrEqual(gain, 4096)
            XCTAssertLessThanOrEqual(samples.map { abs($0) }.max()!, 0.800001)
            XCTAssertEqual(inputRMS, amplitude / sqrt(2), accuracy: amplitude * 0.003)
            expectPitch(samples, profile: .vocals, hz: 440)
        }
    }
    func testGainDoesNotTurnANoiseDominatedToneIntoACertainPitch() {
        for profile in TunerProfile.allCases {
            for amplitude in [0.05, 0.00005, 0.000005] {
                let reading = PitchDetector(profile: profile).analyze(tone(440, amplitude: amplitude, noiseRatio: 5), sampleRate: 48000)
                if case .pitch = reading { XCTFail("Low-SNR input became pitch after gain: \(profile), \(amplitude)") }
            }
        }
    }
    func testNumericalSilenceInvalidInputAndActualRailPlateaus() {
        for profile in TunerProfile.allCases {
            let detector = PitchDetector(profile: profile)
            XCTAssertEqual(detector.analyze([Float](repeating: 0, count: 8640), sampleRate: 48000), .silence)
            XCTAssertEqual(detector.analyze([Float](repeating: 0.25, count: 8640), sampleRate: 48000), .silence)
            XCTAssertEqual(detector.analyze(tone(440, amplitude: 1e-12), sampleRate: 48000), .silence)
            XCTAssertEqual(detector.analyze([Float](repeating: .nan, count: 8640), sampleRate: 48000), .unclear)
            let clipped = tone(440, amplitude: 2).map { min(1, max(-1, $0)) }
            XCTAssertEqual(detector.analyze(clipped, sampleRate: 48000), .clipped)
            expectPitch(tone(440, amplitude: 0.995), profile: profile, hz: 440)
        }
    }
    func testCapturePipelineRecoversQuietAfterLoudSilenceAndNoise() {
        for profile in TunerProfile.allCases {
            let capture = DispatchQueue(label: "level.capture"), analysis = DispatchQueue(label: "level.analysis")
            let processor = PitchCaptureProcessor(profile: profile, algorithm: .current, queue: capture, analysisQueue: analysis)
            let reports = LevelReports()
            var position = 0, seed: UInt64 = 539
            for (amplitude, noise) in [(0.7, false), (0.00003, false), (0.0, false), (0.00003, true), (0.00003, false)] {
                let before = reports.snapshot().count
                for _ in 0..<8 {
                    let start = position
                    let samples: [Float] = (start..<start+4800).map { i in
                        seed = seed &* 6364136223846793005 &+ 1
                        let value = noise ? Double(seed >> 32) / Double(UInt32.max) * 2 - 1
                                          : sin(2 * .pi * 440 * Double(i) / 48000)
                        return Float(amplitude * value)
                    }
                    processor.consume(sampleRate: 48000, sampleTime: Int64(start), copySamples: { samples }, report: reports.add)
                    capture.sync {}; analysis.sync {}; capture.sync {}
                    position += 4800
                }
                let segment = Array(reports.snapshot().dropFirst(before).suffix(2))
                XCTAssertEqual(segment.count, 2)
                for reading in segment {
                    if amplitude > 0 && !noise {
                        guard case let .pitch(hz, _) = reading else { XCTFail("Pipeline did not adapt: \(profile), \(amplitude), \(reading)"); continue }
                        XCTAssertLessThan(abs(1200 * log2(hz / 440)), 1)
                    } else if case .pitch = reading { XCTFail("Stale pitch after silence/noise") }
                }
            }
        }
    }
    func testTonePolicyPreservesTheFullRequestedRangeWithoutASpeakerCutoff() {
        for hz in [20.0, 55, 110, 150, 200, 220, 249.9, 250, 440, 880, 8000] {
            XCTAssertTrue(ToneOutputPolicy.permits(hz))
        }
        for hz in [0.0, 19.9, 8001, .nan, .infinity] {
            XCTAssertFalse(ToneOutputPolicy.permits(hz))
        }
    }
}
