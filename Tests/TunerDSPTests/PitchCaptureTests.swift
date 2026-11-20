import XCTest
import Dispatch
@testable import TunerDSP

private final class PitchReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PitchReading] = []
    func add(_ value: PitchReading) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [PitchReading] { lock.lock(); defer { lock.unlock() }; return values }
}

final class PitchCaptureTests: XCTestCase {
    private func samples(block: Int, count: Int = 4096, rate: Double = 48000) -> [Float] {
        (0..<count).map { Float(0.3 * sin(2 * .pi * 220 * Double(block * 4096 + $0) / rate)) }
    }
    private func expect220(_ reading: PitchReading, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .pitch(hz, confidence) = reading else { return XCTFail("Expected 220 Hz, got \(reading)", file: file, line: line) }
        XCTAssertLessThan(abs(1200 * log2(hz / 220)), 1, file: file, line: line)
        XCTAssertGreaterThan(confidence, 0.99, file: file, line: line)
    }
    func testContiguousFrameContainsOnlyConsecutiveSamples() throws {
        var frames = ContiguousPitchFrames()
        var position = 0, emissions = 0
        for size in [100, 1024, 4096, 4096] {
            let result = frames.append((position..<position+size).map(Float.init), sampleRate: 48000, sampleTime: Int64(position))
            position += size
            XCTAssertFalse(result.discontinuity)
            if let frame = result.samples { emissions += 1; XCTAssertEqual(frame, ((position-8640)..<position).map(Float.init)) }
        }
        XCTAssertEqual(emissions, 1)
        var gap = ContiguousPitchFrames()
        for start in [0, 8192, 16384] {
            XCTAssertNil(gap.append((start..<start+4096).map(Float.init), sampleRate: 48000, sampleTime: Int64(start)).samples)
        }
        XCTAssertNil(gap.append((20480..<24576).map(Float.init), sampleRate: 48000, sampleTime: 20480).samples)
        let recovered = try XCTUnwrap(gap.append((24576..<28672).map(Float.init), sampleRate: 48000, sampleTime: 24576).samples)
        XCTAssertEqual(recovered, (20032..<28672).map(Float.init))
    }
    func testUnknownOverlappingBackwardAndForcedGapResetPartialFrame() {
        for timestamp in [nil, Int64(0), Int64(2048), Int64(-4096)] {
            var frames = ContiguousPitchFrames()
            _ = frames.append(samples(block: 0), sampleRate: 48000, sampleTime: 0)
            let result = frames.append(samples(block: 1), sampleRate: 48000, sampleTime: timestamp)
            XCTAssertTrue(result.discontinuity)
            XCTAssertNil(result.samples)
        }
        var frames = ContiguousPitchFrames()
        _ = frames.append(samples(block: 0), sampleRate: 48000, sampleTime: 0)
        let forced = frames.append(samples(block: 1), sampleRate: 48000, sampleTime: 4096, droppedBefore: true)
        XCTAssertTrue(forced.discontinuity); XCTAssertNil(forced.samples)
        for _ in 0..<3 { XCTAssertNil(frames.append(samples(block: 0), sampleRate: 48000, sampleTime: nil).samples) }
        XCTAssertNotNil(frames.append(samples(block: 0, count: 8640), sampleRate: 48000, sampleTime: nil).samples)
    }
    func testFormatInvalidDataAndTimestampOverflowReset() {
        var frames = ContiguousPitchFrames()
        _ = frames.append(samples(block: 0), sampleRate: 48000, sampleTime: 0)
        let changed = frames.append([Float](repeating: 0.1, count: 500), sampleRate: 16000, sampleTime: 4096)
        XCTAssertTrue(changed.discontinuity); XCTAssertNil(changed.samples)
        for rate in [0.0, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertTrue(frames.append(samples(block: 0), sampleRate: rate, sampleTime: 0).discontinuity)
        }
        XCTAssertTrue(frames.append([], sampleRate: 48000, sampleTime: 0).discontinuity)
        XCTAssertTrue(frames.append([.nan], sampleRate: 48000, sampleTime: 0).discontinuity)
        XCTAssertTrue(frames.append([.infinity], sampleRate: 48000, sampleTime: 0).discontinuity)
        XCTAssertNil(frames.append([Float](repeating: 0, count: 32), sampleRate: 48000, sampleTime: .max - 10).samples)
        XCTAssertTrue(frames.append(samples(block: 0), sampleRate: 48000, sampleTime: 0).discontinuity)
    }
    func testReviewerBackpressureCannotSpliceBuffersAndRecovers() {
        let queue = DispatchQueue(label: "capture.test.backpressure")
        let analysis = DispatchQueue(label: "capture.test.analysis")
        let processor = PitchCaptureProcessor(algorithm: .current, queue: queue, analysisQueue: analysis), reports = PitchReports()
        var copies = 0
        for pair in 0..<3 {
            let hold = DispatchSemaphore(value: 0)
            queue.async { hold.wait() }
            for item in 0..<2 {
                let block = 2 * pair + item
                processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: {
                    copies += 1; return self.samples(block: block)
                }, report: reports.add)
            }
            hold.signal(); queue.sync {}; analysis.sync {}; queue.sync {}
        }
        XCTAssertEqual(copies, 3)
        XCTAssertFalse(reports.snapshot().contains { if case .pitch = $0 { return true }; return false })
        XCTAssertTrue(reports.snapshot().contains(.unclear))
        for block in 6..<9 {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: { self.samples(block: block) }, report: reports.add)
            queue.sync {}; analysis.sync {}; queue.sync {}
        }
        expect220(reports.snapshot().last!)
    }
    func testTimestampGapWithoutWorkerBackpressureAndCopyFailure() {
        let queue = DispatchQueue(label: "capture.test.timestamp")
        let analysis = DispatchQueue(label: "capture.test.analysis")
        let processor = PitchCaptureProcessor(algorithm: .current, queue: queue, analysisQueue: analysis), reports = PitchReports()
        for block in [0, 2, 4] {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: { self.samples(block: block) }, report: reports.add)
            queue.sync {}; analysis.sync {}; queue.sync {}
        }
        XCTAssertFalse(reports.snapshot().contains { if case .pitch = $0 { return true }; return false })
        let countBeforeFailure = reports.snapshot().count
        processor.consume(sampleRate: 48000, sampleTime: 20480, copySamples: { nil }, report: reports.add)
        queue.sync {}; analysis.sync {}; queue.sync {}
        XCTAssertEqual(reports.snapshot().count, countBeforeFailure + 1)
        XCTAssertEqual(reports.snapshot().last, .unclear)
        for block in 6..<9 {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: { self.samples(block: block) }, report: reports.add)
            queue.sync {}; analysis.sync {}; queue.sync {}
        }
        expect220(reports.snapshot().last!)
    }
    func testSlowAnalysisDoesNotBlockCaptureOrCreateUnclearFlicker() {
        let queue = DispatchQueue(label: "capture.test.fast.assembly")
        let analysis = DispatchQueue(label: "capture.test.blocked.analysis")
        let processor = PitchCaptureProcessor(algorithm: .current, queue: queue, analysisQueue: analysis), reports = PitchReports()
        let hold = DispatchSemaphore(value: 0)
        analysis.async { hold.wait() }
        var copies = 0
        for block in 0..<9 {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: {
                copies += 1; return self.samples(block: block)
            }, report: reports.add)
            queue.sync {}
        }
        XCTAssertEqual(copies, 9)
        XCTAssertTrue(reports.snapshot().isEmpty)
        hold.signal(); analysis.sync {}; queue.sync {}
        expect220(reports.snapshot().last!)
        XCTAssertFalse(reports.snapshot().contains(.unclear))
        for block in 9..<12 {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: { self.samples(block: block) }, report: reports.add)
            queue.sync {}; analysis.sync {}; queue.sync {}
        }
        expect220(reports.snapshot().last!)
    }
    func testUnknownTimingSingleBufferFallbackAndStaleAnalysisInvalidation() {
        let queue = DispatchQueue(label: "capture.test.unknown.full")
        let analysis = DispatchQueue(label: "capture.test.unknown.analysis")
        let processor = PitchCaptureProcessor(algorithm: .current, queue: queue, analysisQueue: analysis), reports = PitchReports()
        processor.consume(sampleRate: 48000, sampleTime: nil, copySamples: { self.samples(block: 0, count: 8640) }, report: reports.add)
        queue.sync {}; analysis.sync {}; queue.sync {}
        expect220(reports.snapshot().last!)
        let hold = DispatchSemaphore(value: 0)
        analysis.async { hold.wait() }
        processor.consume(sampleRate: 48000, sampleTime: 0, copySamples: { self.samples(block: 0, count: 8640) }, report: reports.add)
        queue.sync {}
        processor.consume(sampleRate: 48000, sampleTime: 20000, copySamples: { self.samples(block: 3) }, report: reports.add)
        queue.sync {}
        XCTAssertEqual(reports.snapshot().last, .unclear)
        let count = reports.snapshot().count
        hold.signal(); analysis.sync {}; queue.sync {}
        XCTAssertEqual(reports.snapshot().count, count, "The old in-flight result must not overwrite the gap indication")
    }
    func testOverloadCopiesAtMostOneBufferAndUnknownTimesNeverSplice() {
        let queue = DispatchQueue(label: "capture.test.bounded")
        let analysis = DispatchQueue(label: "capture.test.analysis")
        let processor = PitchCaptureProcessor(algorithm: .current, queue: queue, analysisQueue: analysis), reports = PitchReports()
        let hold = DispatchSemaphore(value: 0)
        queue.async { hold.wait() }
        var copies = 0
        for block in 0..<128 {
            processor.consume(sampleRate: 48000, sampleTime: Int64(block * 4096), copySamples: {
                copies += 1; return self.samples(block: block)
            }, report: reports.add)
        }
        XCTAssertEqual(copies, 1)
        hold.signal(); queue.sync {}; analysis.sync {}; queue.sync {}
        for block in 128..<132 {
            processor.consume(sampleRate: 48000, sampleTime: nil, copySamples: { self.samples(block: block) }, report: reports.add)
            queue.sync {}; analysis.sync {}; queue.sync {}
        }
        XCTAssertFalse(reports.snapshot().contains { if case .pitch = $0 { return true }; return false })
    }
}
