import XCTest
@testable import TunerDSP

final class ToneCrownTests: XCTestCase {
    func testSmallBumpsAndSeparateGesturesDoNotChangeFrequency() {
        var filter = ToneCrownFilter()
        XCTAssertNil(filter.turn(delta: 0.15, frequency: 440, at: 0))
        XCTAssertNil(filter.turn(delta: 0.15, frequency: 440, at: 0.1))
        filter.reset()
        XCTAssertNil(filter.turn(delta: 0.15, frequency: 440, at: 0.2))
        XCTAssertNil(filter.turn(delta: 0.1, frequency: 440, at: 0.6))
        XCTAssertNil(filter.turn(delta: -0.1, frequency: 440, at: 0.7))
    }
    func testDeliberateTurnUsesCoarseStepsWithoutLosingRemainder() {
        var filter = ToneCrownFilter()
        XCTAssertNil(filter.turn(delta: 0.399, frequency: 440, at: 0))
        XCTAssertEqual(filter.turn(delta: 0.001, frequency: 440, at: 0.01), 450)
        XCTAssertNil(filter.turn(delta: 0.099, frequency: 450, at: 0.02))
        XCTAssertEqual(filter.turn(delta: 0.001, frequency: 450, at: 0.03), 460)
        XCTAssertEqual(filter.turn(delta: 0.2, frequency: 460, at: 0.04), 480)
        XCTAssertNil(filter.turn(delta: -0.1, frequency: 480, at: 0.05))
        XCTAssertEqual(filter.turn(delta: -0.3, frequency: 480, at: 0.06), 470)
    }
    func testLongContinuousTurnsNeverReverseAndNewGesturesKeepFrequency() {
        var filter = ToneCrownFilter()
        var hz = 440.0
        for i in 0..<100 {
            let next = filter.turn(delta: 0.2, frequency: hz, at: Double(i) * 0.02) ?? hz
            XCTAssertGreaterThanOrEqual(next, hz)
            hz = next
        }
        XCTAssertGreaterThan(hz, 2000)
        filter.reset()
        XCTAssertNil(filter.turn(delta: 0.3, frequency: hz, at: 3))
        XCTAssertEqual(filter.turn(delta: 0.1, frequency: hz, at: 3.1), hz + 10)
        filter.reset()
        for i in 0..<100 {
            let next = filter.turn(delta: -0.2, frequency: hz, at: 4 + Double(i) * 0.02) ?? hz
            XCTAssertLessThanOrEqual(next, hz)
            hz = next
        }
        XCTAssertEqual(hz, 440)
    }
    func testBoundariesResetAndInvalidEvents() {
        var filter = ToneCrownFilter()
        XCTAssertEqual(filter.turn(delta: 0.6, frequency: 7999, at: 0), 8000)
        filter.reset()
        XCTAssertEqual(filter.turn(delta: -0.6, frequency: 21, at: 1), 20)
        filter.reset()
        XCTAssertNil(filter.turn(delta: 0.05, frequency: 440, at: 2))
        XCTAssertNil(filter.turn(delta: .nan, frequency: 440, at: 2.1))
        XCTAssertNil(filter.turn(delta: 0.05, frequency: 440, at: 2.2))
        XCTAssertNil(filter.turn(delta: 0.02, frequency: 440, at: 1))
        XCTAssertNil(filter.turn(delta: 0, frequency: 440, at: 1.1))
    }
}
