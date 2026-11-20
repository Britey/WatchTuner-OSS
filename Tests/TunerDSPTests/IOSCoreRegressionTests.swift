import XCTest
import Dispatch
@testable import TunerDSP

private final class IOSCoreReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PitchReading] = []
    func append(_ reading: PitchReading) {
        lock.lock(); defer { lock.unlock() }; values.append(reading)
    }
    func snapshot() -> [PitchReading] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

/// Offline PCM inputs use the same production configuration, admission, frame
/// assembly, analysis worker and tracker as the app. No microphone or engine.
final class IOSCoreRegressionTests: XCTestCase {
    private func tone(_ hz: Double, sampleRate: Double, count: Int, start: Int = 0) -> [Float] {
        (start..<start + count).map { Float(0.12 * sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    private func feed(_ samples: [Float], sampleRate: Double, blockSize: Int,
                      processor: PitchCaptureProcessor, capture: DispatchQueue,
                      analysis: DispatchQueue) -> [PitchReading] {
        let reports = IOSCoreReports()
        for start in stride(from: 0, to: samples.count, by: blockSize) {
            let buffer = Array(samples[start..<min(start + blockSize, samples.count)])
            processor.consume(sampleRate: sampleRate, sampleTime: Int64(start), copySamples: { buffer }, report: reports.append)
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        return reports.snapshot()
    }

    func testProductionPCMAcrossPhoneSampleRatesAndTapSizes() {
        for rate in [44100.0, 48000] {
            for profile in TunerProfile.allCases {
                for hz in [110.0, 440, 880] {
                    for blockSize in [1024, Int(rate / 10)] {
                        let capture = DispatchQueue(label: "ios.matrix.capture")
                        let analysis = DispatchQueue(label: "ios.matrix.analysis")
                        let processor = PitchCaptureProcessor(configuration: .production(profile: profile), queue: capture, analysisQueue: analysis)
                        let input = tone(hz, sampleRate: rate, count: Int(rate * 0.6))
                        let reports = feed(input, sampleRate: rate, blockSize: blockSize,
                                           processor: processor, capture: capture, analysis: analysis)
                        let voiced = reports.compactMap { reading -> Double? in
                            if case let .pitch(actual, _) = reading { return actual }; return nil
                        }
                        let context = "\(profile) \(hz)Hz \(rate)Hz tap=\(blockSize)"
                        XCTAssertGreaterThanOrEqual(voiced.count, 2, context)
                        for actual in voiced {
                            XCTAssertLessThan(abs(1200 * log2(actual / hz)), 3, context)
                        }
                        XCTAssertTrue(reports.contains { if case .pitch = $0 { true } else { false } }, context)
                    }
                }
            }
        }
    }

    func testRepeatedNewCaptureSessionsStartFreshAndClearAtSilence() {
        let capture = DispatchQueue(label: "ios.sessions.capture")
        let analysis = DispatchQueue(label: "ios.sessions.analysis")
        for session in 0..<9 {
            let rate = session.isMultiple(of: 2) ? 44100.0 : 48000.0
            let hz = session.isMultiple(of: 2) ? 220.0 : 659.255
            let profile = TunerProfile.allCases[session % TunerProfile.allCases.count]
            let processor = PitchCaptureProcessor(configuration: .production(profile: profile), queue: capture, analysisQueue: analysis)
            let voiced = tone(hz, sampleRate: rate, count: Int(rate * 0.6))
            let input = voiced + [Float](repeating: 0, count: Int(rate * 0.6))
            let reports = feed(input, sampleRate: rate, blockSize: Int(rate / 10),
                               processor: processor, capture: capture, analysis: analysis)
            let pitches = reports.compactMap { reading -> Double? in
                if case let .pitch(actual, _) = reading { return actual }; return nil
            }
            XCTAssertFalse(pitches.isEmpty, "session \(session)")
            XCTAssertTrue(pitches.allSatisfy { abs(1200 * log2($0 / hz)) < 3 }, "session \(session) retained a previous pitch")
            XCTAssertEqual(reports.last, .silence, "session \(session) retained a pitch after silence")
        }
    }

    func testSampleRateChangeRejectsOldAssemblyAndRecoversAtNewRate() {
        for profile in TunerProfile.allCases {
            let capture = DispatchQueue(label: "ios.rate.capture")
            let analysis = DispatchQueue(label: "ios.rate.analysis")
            let processor = PitchCaptureProcessor(configuration: .production(profile: profile), queue: capture, analysisQueue: analysis)
            _ = feed(tone(220, sampleRate: 48000, count: 4800), sampleRate: 48000, blockSize: 4800,
                     processor: processor, capture: capture, analysis: analysis)
            // The new route restarts sample time at zero with a different rate
            // and pitch. Any splice would combine two incompatible time bases.
            let reports = feed(tone(440, sampleRate: 44100, count: 26460), sampleRate: 44100, blockSize: 4410,
                               processor: processor, capture: capture, analysis: analysis)
            XCTAssertEqual(reports.first, .unclear)
            let pitches = reports.compactMap { reading -> Double? in
                if case let .pitch(actual, _) = reading { return actual }; return nil
            }
            XCTAssertGreaterThanOrEqual(pitches.count, 2)
            XCTAssertTrue(pitches.allSatisfy { abs(1200 * log2($0 / 440)) < 3 })
        }
    }
}
