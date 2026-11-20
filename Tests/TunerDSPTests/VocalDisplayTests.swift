import XCTest
@testable import TunerDSP

final class VocalDisplayTests: XCTestCase {
    private func pitch(_ hz: Double) -> PitchReading { .pitch(hz: hz, confidence: 0.95) }
    private func hz(_ reading: PitchReading, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case let .pitch(value, confidence) = reading else { XCTFail("Expected pitch", file: file, line: line); return .nan }
        XCTAssertEqual(confidence, 0.95, file: file, line: line)
        return value
    }
    func testSteadyVocalJitterIsReducedWithoutNoteSnapping() {
        for interval in [0.02, 0.1, 0.18] {
            var filter = VocalDisplaySmoother(), output: [Double] = []
            for i in 0..<100 {
                let cents = i.isMultiple(of: 2) ? -25.0 : 25.0
                let result = filter.accept(pitch(445 * pow(2, cents / 1200)), profile: .vocals, at: Double(i) * interval)
                if i > 30 { output.append(1200 * log2(hz(result) / 445)) }
            }
            let span = (output.max() ?? 0) - (output.min() ?? 0)
            XCTAssertLessThan(span, 22) // raw span: 50 cents, including 180 ms updates
            XCTAssertGreaterThan(span, 0.1) // averaging, not snapping or freezing
            XCTAssertLessThan(abs(output.reduce(0, +) / Double(output.count)), 1)
        }
    }
    func testMusicalChangesConvergeWithoutHoldingTheOldNote() {
        var filter = VocalDisplaySmoother()
        _ = filter.accept(pitch(440), profile: .vocals, at: 0)
        var value = 440.0
        let next = 440 * pow(2, 100.0 / 1200)
        for i in 1...6 { value = hz(filter.accept(pitch(next), profile: .vocals, at: Double(i) * 0.1)) }
        XCTAssertLessThan(abs(1200 * log2(value / next)), 7)
        let leap = hz(filter.accept(pitch(660), profile: .vocals, at: 0.7))
        XCTAssertGreaterThan(leap, 600)
        XCTAssertLessThan(leap, 660)
    }
    func testSilenceUncertaintyAndOverloadClearImmediatelyAndReacquireFresh() {
        for empty in [PitchReading.silence, .unclear, .clipped] {
            var filter = VocalDisplaySmoother()
            _ = filter.accept(pitch(440), profile: .vocals, at: 0)
            XCTAssertEqual(filter.accept(empty, profile: .vocals, at: 0.1), empty)
            XCTAssertEqual(hz(filter.accept(pitch(220), profile: .vocals, at: 0.2)), 220, accuracy: 1e-9)
        }
    }
    func testOtherProfilesPassRawAndResetVocalHistory() {
        for profile in [TunerProfile.guitar, .piano] {
            var filter = VocalDisplaySmoother()
            _ = filter.accept(pitch(440), profile: .vocals, at: 0)
            XCTAssertEqual(filter.accept(pitch(442), profile: profile, at: 0.1), pitch(442))
            XCTAssertEqual(filter.accept(pitch(330), profile: .vocals, at: 0.2), pitch(330))
        }
    }
    func testResetsGapsClockChangesAndInvalidData() {
        for nextTime in [1.0, 0.0, -1.0] {
            var filter = VocalDisplaySmoother()
            _ = filter.accept(pitch(440), profile: .vocals, at: 0)
            XCTAssertEqual(filter.accept(pitch(330), profile: .vocals, at: nextTime), pitch(330))
        }
        var filter = VocalDisplaySmoother()
        _ = filter.accept(pitch(440), profile: .vocals, at: 0)
        filter.reset()
        XCTAssertEqual(filter.accept(pitch(330), profile: .vocals, at: 0.1), pitch(330))
        XCTAssertEqual(filter.accept(pitch(.nan), profile: .vocals, at: 0.2), .unclear)
        XCTAssertEqual(filter.accept(pitch(0), profile: .vocals, at: 0.3), .unclear)
        XCTAssertEqual(filter.accept(pitch(440), profile: .vocals, at: .nan), .unclear)
    }
}
