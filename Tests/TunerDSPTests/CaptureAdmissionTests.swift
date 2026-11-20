import XCTest
import Dispatch
@testable import TunerDSP

private final class AdmissionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [(PitchReading, UInt64)] = []
    private var actions: [CaptureTimingAction] = []
    func add(_ reading: PitchReading, _ revision: UInt64) {
        lock.lock(); defer { lock.unlock() }; readings.append((reading, revision))
    }
    func action(_ value: CaptureTimingAction) {
        lock.lock(); defer { lock.unlock() }; actions.append(value)
    }
    var reports: [(PitchReading, UInt64)] {
        lock.lock(); defer { lock.unlock() }; return readings
    }
    var timing: [CaptureTimingAction] {
        lock.lock(); defer { lock.unlock() }; return actions
    }
}

final class CaptureAdmissionTests: XCTestCase {
    private func signal(_ hz: Double, count: Int = 8640, start: Int = 0) -> [Float] {
        (0..<count).map { Float(0.12*sin(2 * .pi * hz*Double(start+$0)/48000)) }
    }
    private func drain(_ capture: DispatchQueue, _ analysis: DispatchQueue) {
        capture.sync {}; analysis.sync {}; capture.sync {}
    }

    func testCaptureQueuedBeforeProfileEditCannotBeRelabeledIncludingReturnToSameProfile() {
        for timestampValid in [false, true] {
            for returnToPiano in [false, true] {
                let capture = DispatchQueue(label: "admission.profile.capture")
                let analysis = DispatchQueue(label: "admission.profile.analysis")
                let processor = PitchCaptureProcessor(configuration: .production(profile: .piano), queue: capture, analysisQueue: analysis)
                let events = AdmissionEvents(), hold = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
                capture.async { entered.signal(); hold.wait() }
                XCTAssertEqual(entered.wait(timeout: .now()+2), .success)
                let old = processor.revision, input = signal(440)
                processor.consumeVersioned(sampleRate: 48000, sampleTime: timestampValid ? 0 : nil,
                                           copySamples: { input }, report: events.add)
                processor.setConfiguration(.production(profile: .guitar))
                if returnToPiano { processor.setConfiguration(.production(profile: .piano)) }
                XCTAssertNotEqual(old, processor.revision)
                hold.signal(); drain(capture, analysis)
                XCTAssertTrue(events.reports.isEmpty, "Old audio must not emit even unclear under a new revision")
                // A rejected buffer must release admission and allow fresh audio.
                for index in 0..<3 {
                    let input = signal(660, start: index*8640)
                    processor.consumeVersioned(sampleRate: 48000, sampleTime: timestampValid ? Int64(index*8640) : nil,
                                               copySamples: { input }, report: events.add)
                    drain(capture, analysis)
                }
                let pitches = events.reports.compactMap { reading, revision -> Double? in
                    XCTAssertEqual(revision, processor.revision)
                    if case let .pitch(hz, _) = reading { return hz }; return nil
                }
                XCTAssertFalse(pitches.isEmpty)
                XCTAssertTrue(pitches.allSatisfy { abs(1200*log2($0/660)) < 2 })
            }
        }
    }

    func testConfigurationSnapshotPrecedesSampleCopy() {
        let capture = DispatchQueue(label: "admission.copy.capture"), analysis = DispatchQueue(label: "admission.copy.analysis")
        let processor = PitchCaptureProcessor(configuration: .production(profile: .piano), queue: capture, analysisQueue: analysis)
        let events = AdmissionEvents(), input = signal(440), old = processor.revision
        processor.consumeVersioned(sampleRate: 48000, sampleTime: nil, copySamples: {
            // Models a UI edit racing the synchronous tap copy, without sleeps.
            processor.setConfiguration(.production(profile: .guitar))
            return input
        }, report: events.add)
        drain(capture, analysis)
        XCTAssertNotEqual(old, processor.revision)
        XCTAssertTrue(events.reports.isEmpty)
    }

    func testObsoleteAdmissionDoesNotConsumeTimingRetryBudget() {
        let capture = DispatchQueue(label: "admission.timing.capture"), analysis = DispatchQueue(label: "admission.timing.analysis")
        let events = AdmissionEvents()
        let processor = PitchCaptureProcessor(configuration: .production(profile: .piano), timingAction: events.action,
                                              queue: capture, analysisQueue: analysis)
        let partial = signal(440, count: 1024)
        for _ in 0..<3 {
            let hold = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
            capture.async { entered.signal(); hold.wait() }
            XCTAssertEqual(entered.wait(timeout: .now()+2), .success)
            processor.consumeVersioned(sampleRate: 48000, sampleTime: nil, copySamples: { partial }, report: events.add)
            // Same algorithm/profile again still has a different revision.
            processor.setConfiguration(.production(profile: .guitar))
            processor.setConfiguration(.production(profile: .piano))
            hold.signal(); drain(capture, analysis)
        }
        XCTAssertTrue(events.reports.isEmpty)
        XCTAssertTrue(events.timing.isEmpty, "Obsolete audio must not trigger replacement of the current tap")
        for index in 0..<3 {
            processor.consumeVersioned(sampleRate: 48000, sampleTime: nil, copySamples: { partial }, report: events.add)
            drain(capture, analysis)
            XCTAssertEqual(events.timing.count, index == 2 ? 1 : 0)
        }
        XCTAssertEqual(events.timing, [.retryLargerTap(frames: 8640)])
    }
}
