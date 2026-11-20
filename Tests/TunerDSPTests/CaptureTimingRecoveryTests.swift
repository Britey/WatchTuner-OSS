import XCTest
import Dispatch
@testable import TunerDSP

private final class TimingActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CaptureTimingAction] = []
    func add(_ action: CaptureTimingAction) { lock.lock(); defer { lock.unlock() }; values.append(action) }
    var snapshot: [CaptureTimingAction] { lock.lock(); defer { lock.unlock() }; return values }
}
final class CaptureTimingRecoveryTests: XCTestCase {
    func testOneRetryThenBoundedFailureAndResetOnlyOnNewStart() {
        var policy = CaptureTimingRecovery()
        for _ in 0..<2 { XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
        XCTAssertEqual(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false), .retryLargerTap(frames: 8640))
        for _ in 0..<10 { XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
        var replacement = CaptureTimingRecovery(largerTapAttempted: true)
        for _ in 0..<2 { XCTAssertNil(replacement.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
        XCTAssertEqual(replacement.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false), .unavailable)
        for _ in 0..<10 { XCTAssertNil(replacement.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
    }
    func testValidTimeOrIndependentFullWindowResetsConsecutiveCount() {
        var policy = CaptureTimingRecovery()
        for _ in 0..<3 {
            for _ in 0..<2 { XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
            XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: true))
            for _ in 0..<2 { XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 1024, timestampValid: false)) }
            XCTAssertNil(policy.observe(sampleRate: 48000, frameCount: 8640, timestampValid: false))
        }
        for rate in [8000.0, 44100, 48000, 96000, 192000] {
            let initial = Double(CaptureTimingRecovery.initialTapFrames(sampleRate: rate)) / rate
            let retry = Double(CaptureTimingRecovery.windowFrames(sampleRate: rate)) / rate
            XCTAssertGreaterThanOrEqual(initial, 0.1); XCTAssertLessThanOrEqual(initial, 0.4)
            XCTAssertGreaterThanOrEqual(retry, 0.18); XCTAssertLessThanOrEqual(retry, 0.4)
        }
    }
    func testProcessorInvokesRecoveryWithoutJoiningUnknownBuffersOrResettingBudgetOnProfileEdits() {
        let capture = DispatchQueue(label: "timing.capture"), analysis = DispatchQueue(label: "timing.analysis")
        let actions = TimingActions(), reports = TimingActions()
        let processor = PitchCaptureProcessor(profile: .vocals, algorithm: .current, timingAction: actions.add, queue: capture, analysisQueue: analysis)
        for profile in [TunerProfile.vocals, .piano, .guitar, .vocals, .piano] {
            processor.setProfile(profile)
            processor.consume(sampleRate: 48000, sampleTime: nil, copySamples: { [Float](repeating: 0.2, count: 1024) }) {
                if case .pitch = $0 { reports.add(.unavailable) }
            }
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        XCTAssertEqual(actions.snapshot, [.retryLargerTap(frames: 8640)])
        XCTAssertTrue(reports.snapshot.isEmpty)
        // Discontinuous but valid timestamps must not trigger a tap retry.
        let knownActions = TimingActions()
        let known = PitchCaptureProcessor(algorithm: .current, timingAction: knownActions.add, queue: capture, analysisQueue: analysis)
        for time in [Int64(0), 20000, -5000, 90000] {
            known.consume(sampleRate: 48000, sampleTime: time, copySamples: { [Float](repeating: 0.2, count: 1024) }, report: { _ in })
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        XCTAssertTrue(knownActions.snapshot.isEmpty)
    }
}
