import XCTest
@testable import TunerDSP

/// A monophonic policy: tolerate bounded weak interference, reject unresolved
/// competing sources, and never invent a missing root from a weak foreign peak.
final class PitchInterferenceTests: XCTestCase {
    private let detector = PitchDetector()
    private func signal(_ partials: [(Double, Double, Double)], rate: Double = 48000) -> [Float] {
        (0..<Int(rate * 0.18)).map { i in
            let time = Double(i) / rate
            return Float(partials.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * time + $1.2) })
        }
    }
    @discardableResult private func correctOrUnclear(_ reading: PitchReading, hz: Double, cents: Double = 4,
                                                     file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if case let .pitch(actual, _) = reading {
            XCTAssertLessThan(abs(1200 * log2(actual / hz)), cents, "\(hz) → \(reading)", file: file, line: line)
            return true
        }
        XCTAssertEqual(reading, .unclear, file: file, line: line)
        return false
    }
    func testBrightMonophonicSpectraThrough48Partials() {
        for rate in [16000.0, 44100, 48000] {
            for hz in [55.0, 82, 110, 147] {
                for count in [8, 16, 24, 32, 48] {
                    let partials = (1...count).map { (hz * Double($0), 0.3 / Double($0), 0.0) }
                    XCTAssertTrue(correctOrUnclear(detector.analyze(signal(partials, rate: rate), sampleRate: rate), hz: hz))
                }
            }
        }
    }
    func testWeakExtraneousPeaksDoNotEstablishAbsentSubharmonic() {
        for hz in [82.0, 220, 440, 880] {
            for ratio in [1.5, 2.5, 4.0/3, 5.0/3, 1.25, 1.75, 1.2] {
                for gain in [0.012, 0.03] {
                    let reading = detector.analyze(signal([(hz, 0.3, 0), (hz * ratio, gain, 0)]), sampleRate: 48000)
                    // These inputs satisfy the documented dominant-source budget.
                    XCTAssertTrue(correctOrUnclear(reading, hz: hz))
                }
            }
        }
    }
    func testWeakHumDoesNotInvalidateDominantResolvedTone() {
        for hz in [110.0, 220, 440, 880] {
            for rate in [16000.0, 44100, 48000] {
                let reading = detector.analyze(signal([(hz, 0.3, 0), (60, 0.015, 0.7)], rate: rate), sampleRate: rate)
                XCTAssertTrue(correctOrUnclear(reading, hz: hz))
            }
        }
    }
    func testStretchedUpperPartialsDoNotPullFirstPartialSharp() {
        for hz in [82.0, 110, 220, 440] {
            for stiffness in [0.00005, 0.0002, 0.0005] {
                let partials = (1...8).map { h in
                    (hz * Double(h) * sqrt(1 + stiffness * Double(h * h)), 0.3 / Double(h), 0.0)
                }
                let resolved = correctOrUnclear(detector.analyze(signal(partials), sampleRate: 48000),
                                                hz: hz * sqrt(1 + stiffness), cents: 1)
                if stiffness <= 0.0002 { XCTAssertTrue(resolved) }
            }
        }
    }
    func testReviewerSeed104729ContaminationAndCleanControls() {
        var state: UInt64 = 104729
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state >> 32) / Double(UInt32.max)
        }
        var reports = 0
        for index in 0..<300 {
            let hz = 110 + random() * 770, ratio = 0.6 + random() * 3, phase = random() * 2 * .pi
            let partials = (1...4).map { (hz * Double($0), 0.3 / Double($0), 0.0) }
            if index < 100 { XCTAssertTrue(correctOrUnclear(detector.analyze(signal(partials), sampleRate: 48000), hz: hz)) }
            if correctOrUnclear(detector.analyze(signal(partials + [(hz * ratio, 0.03, phase)]), sampleRate: 48000), hz: hz) { reports += 1 }
        }
        XCTAssertGreaterThanOrEqual(reports, 240, "Do not fix wrong pitches by rejecting the corpus")
        print("reviewer_contamination total=300 reported=\(reports) unclear=\(300-reports) clean_controls=100")
    }
    func testSubstantialUnresolvedSourcesAreAmbiguous() {
        for ratio in [sqrt(2.0), sqrt(3.0)] {
            let input = signal([(440, 0.3, 0), (440 * ratio, 0.25, 0.3)])
            XCTAssertEqual(detector.analyze(input, sampleRate: 48000), .unclear)
        }
        // Above the interference budget but too weak to establish an absent root:
        // reject rather than infer 220 Hz from partials at 440 and 660 Hz.
        XCTAssertEqual(detector.analyze(signal([(440, 0.3, 0), (660, 0.06, 0)]), sampleRate: 48000), .unclear)
    }
}
