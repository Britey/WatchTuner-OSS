import XCTest
@testable import TunerDSP

final class TunerDSPTests: XCTestCase {
    let detector = PitchDetector()
    func tone(_ hz: Double, rate: Double = 48000, amplitude: Double = 0.3, harmonic: Double = 0, dc: Double = 0) -> [Float] {
        (0..<Int(rate * 0.18)).map { i in
            let phase = 2 * Double.pi * hz * Double(i) / rate
            return Float(dc + amplitude * sin(phase) + harmonic * sin(phase * 2))
        }
    }
    func assertPitch(_ samples: [Float], rate: Double, hz: Double, cents: Double = 4, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .pitch(actual, confidence) = detector.analyze(samples, sampleRate: rate) else {
            return XCTFail("No pitch for \(hz) Hz", file: file, line: line)
        }
        XCTAssertLessThan(abs(1200 * log2(actual / hz)), cents, "\(hz) → \(actual)", file: file, line: line)
        XCTAssertGreaterThan(confidence, 0.85, file: file, line: line)
    }
    func testKnownTonesAndRates() {
        for rate in [16000.0, 44100, 48000] {
            for hz in [55.0, 65.4064, 82.4069, 110, 220, 440, 442, 880, 1000, 1760, 1850, 1987, 2000] {
                assertPitch(tone(hz, rate: rate), rate: rate, hz: hz)
            }
        }
    }
    func testHarmonicsDCAndQuietSignal() {
        assertPitch(tone(146.832, amplitude: 0.12, harmonic: 0.3, dc: 0.15), rate: 48000, hz: 146.832)
        assertPitch(tone(440, amplitude: 0.008), rate: 48000, hz: 440)
    }
    func testSilenceNoiseAndClipping() {
        XCTAssertEqual(detector.analyze([Float](repeating: 0, count: 8640), sampleRate: 48000), .silence)
        XCTAssertEqual(detector.analyze([Float](repeating: 0.2, count: 8640), sampleRate: 48000), .silence)
        assertPitch(tone(440, amplitude: 0.001), rate: 48000, hz: 440)
        var state: UInt64 = 42
        let noise: [Float] = (0..<8640).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5)
        }
        XCTAssertEqual(detector.analyze(noise, sampleRate: 48000), .unclear)
        XCTAssertEqual(detector.analyze(tone(440, amplitude: 2).map { min(1, max(-1, $0)) }, sampleRate: 48000), .clipped)
        XCTAssertEqual(detector.analyze([.nan], sampleRate: 48000), .unclear)
    }
    func testNoteMappingAndBoundaries() throws {
        let a = try XCTUnwrap(MusicalNote(frequency: 440))
        XCTAssertEqual(a.name, "A4"); XCTAssertEqual(a.midi, 69)
        XCTAssertEqual(a.referenceHz, 440); XCTAssertEqual(a.cents, 0, accuracy: 1e-9)
        for cents in [-49.9, -25, 25, 49.9] {
            let note = try XCTUnwrap(MusicalNote(frequency: 440 * pow(2, cents / 1200)))
            XCTAssertEqual(note.midi, 69); XCTAssertEqual(note.cents, cents, accuracy: 1e-8)
        }
        XCTAssertEqual(MusicalNote(frequency: 440 * pow(2, 50.1 / 1200))?.name, "A♯4")
        XCTAssertEqual(MusicalNote(frequency: 261.625565)?.name, "C4")
        for bad in [0.0, -1, .nan, .infinity] { XCTAssertNil(MusicalNote(frequency: bad)) }
        XCTAssertEqual(detector.analyze(tone(40), sampleRate: 48000), .unclear)
        XCTAssertEqual(detector.analyze(tone(2100), sampleRate: 48000), .unclear)
        XCTAssertEqual(detector.analyze(tone(4000), sampleRate: 48000), .unclear)
        XCTAssertEqual(detector.analyze(tone(24440), sampleRate: 48000), .unclear)
    }
    func testOscillatorAmplitudeContinuityAndFade() {
        var oscillator = SineOscillator()
        var samples: [Float] = []
        for _ in 0..<24000 { samples.append(oscillator.next(sampleRate: 48000, targetHz: 440, targetAmplitude: 1)) }
        XCTAssertEqual(samples[0], 0)
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max()!, 0.150001)
        assertPitch(Array(samples.suffix(8640)), rate: 48000, hz: 440)
        var last = samples.last!
        var maximumJump: Float = 0
        for i in 0..<12000 {
            let sample = oscillator.next(sampleRate: 48000, targetHz: i < 6000 ? 880 : 220, targetAmplitude: 0.1)
            maximumJump = max(maximumJump, abs(sample - last)); last = sample
        }
        XCTAssertLessThan(maximumJump, 0.025)
        for _ in 0..<12000 { last = oscillator.next(sampleRate: 48000, targetHz: 220, targetAmplitude: 0) }
        XCTAssertLessThan(abs(last), 1e-8)
        XCTAssertLessThan(oscillator.amplitude, 1e-8)
        XCTAssertTrue(oscillator.phase >= 0 && oscillator.phase < 2 * .pi)
    }
    func testOscillatorLimitsAndInvalidArguments() {
        var oscillator = SineOscillator()
        for _ in 0..<24000 { _ = oscillator.next(sampleRate: 16000, targetHz: 9000, targetAmplitude: 0.1) }
        XCTAssertEqual(oscillator.frequency, 7200, accuracy: 0.001)
        XCTAssertEqual(oscillator.next(sampleRate: 0, targetHz: 440, targetAmplitude: 0.1), 0)
        XCTAssertEqual(oscillator.next(sampleRate: 48000, targetHz: .nan, targetAmplitude: 0.1), 0)
    }
}
