import XCTest
import Dispatch
@testable import TunerDSP

private final class CandidateReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(PitchReading, UInt64)] = []
    func add(_ value: PitchReading, _ revision: UInt64) { lock.lock(); defer { lock.unlock() }; values.append((value, revision)) }
    func snapshot() -> [(PitchReading, UInt64)] { lock.lock(); defer { lock.unlock() }; return values }
}

final class AlternativePitchTests: XCTestCase {
    private func signal(_ hz: Double, rate: Double = 48000, amplitude: Double = 0.00003) -> [Float] {
        (0..<Int(rate * 0.18)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }
    func testRetainedAlgorithmsKeepStableConfigurationCodes() {
        XCTAssertEqual(PitchAlgorithm.allCases, [.current, .noiseAware, .mcleod])
        XCTAssertEqual(PitchAlgorithm.current.code, 0)
        XCTAssertEqual(PitchAlgorithm.noiseAware.code, 1)
        XCTAssertEqual(PitchAlgorithm.mcleod.code, 3)
        for algorithm in PitchAlgorithm.allCases {
            XCTAssertEqual(PitchAlgorithm(code: algorithm.code), algorithm)
        }
        // A retired or invalid code must not select a historical estimator.
        for code: UInt64 in [2, 4, UInt64.max] {
            XCTAssertEqual(PitchAlgorithm(code: code), .mcleod)
        }
        for profile in TunerProfile.allCases {
            let configuration = PitchConfiguration.production(profile: profile)
            XCTAssertEqual(configuration.algorithm, .mcleod)
            XCTAssertEqual(configuration.code, profile.code | (3 << 2))
        }
    }
    func testQuietTonesAcrossCandidatesProfilesAndRates() {
        for algorithm in PitchAlgorithm.allCases {
            for profile in TunerProfile.allCases {
                for rate in [16000.0, 44100, 48000] {
                    for hz in [110.0, 440, 880] {
                        let result = algorithm.analyze(signal(hz, rate: rate), sampleRate: rate, profile: profile)
                        guard case let .pitch(actual, _) = result else { XCTFail("\(algorithm)/\(profile): \(result)"); continue }
                        XCTAssertLessThan(abs(1200 * log2(actual/hz)), 6, "\(algorithm)/\(profile) \(rate)")
                    }
                }
            }
        }
    }
    func testCandidatesNumericalSilenceOverloadNoiseAndInvalidInput() {
        for algorithm in PitchAlgorithm.allCases {
            XCTAssertEqual(algorithm.analyze([Float](repeating: 0, count: 8640), sampleRate: 48000, profile: .piano), .silence)
            XCTAssertEqual(algorithm.analyze([Float](repeating: .nan, count: 8640), sampleRate: 48000, profile: .piano), .unclear)
            XCTAssertEqual(algorithm.analyze(signal(440), sampleRate: .nan, profile: .piano), .unclear)
            let clipped = signal(440, amplitude: 2).map { min(1, max(-1, $0)) }
            XCTAssertEqual(algorithm.analyze(clipped, sampleRate: 48000, profile: .piano), .clipped)
            // Ordinary broadband noise must not become a note. Very strongly
            // colored room noise can still mislead an experimental candidate.
            for seed in 1...12 {
                var state = UInt64(seed)
                let noise: [Float] = (0..<8640).map { _ in
                    state = state &* 6364136223846793005 &+ 1
                    return Float(Double(state >> 32) / Double(UInt32.max) * 0.00006 - 0.00003)
                }
                XCTAssertEqual(algorithm.analyze(noise, sampleRate: 48000, profile: .piano), .unclear, "\(algorithm) seed \(seed)")
            }
        }
    }
    func testLiveAlgorithmChangesInvalidatePendingResultsAndKeepProfile() {
        let capture = DispatchQueue(label: "candidate.capture"), analysis = DispatchQueue(label: "candidate.analysis")
        let processor = PitchCaptureProcessor(profile: .piano, algorithm: .current, queue: capture, analysisQueue: analysis)
        let reports = CandidateReports(), hold = DispatchSemaphore(value: 0)
        analysis.async { hold.wait() }
        let input = signal(440)
        processor.consumeVersioned(sampleRate: 48000, sampleTime: 0, copySamples: { input }, report: reports.add)
        capture.sync {}
        let old = processor.revision
        processor.setAlgorithm(.noiseAware); processor.setAlgorithm(.current)
        XCTAssertNotEqual(old, processor.revision)
        hold.signal(); analysis.sync {}; capture.sync {}
        XCTAssertTrue(reports.snapshot().isEmpty)
        for algorithm in PitchAlgorithm.allCases {
            processor.setAlgorithm(algorithm)
            XCTAssertEqual(processor.revision & 3, TunerProfile.piano.code)
            for index in 0..<3 {
                processor.consumeVersioned(sampleRate: 48000, sampleTime: Int64(index * 8640), copySamples: { input }, report: reports.add)
                capture.sync {}; analysis.sync {}; capture.sync {}
            }
            guard case let .pitch(hz, _) = reports.snapshot().last!.0 else { XCTFail("\(algorithm) did not acquire"); continue }
            XCTAssertLessThan(abs(1200 * log2(hz/440)), 6)
            XCTAssertEqual(reports.snapshot().last!.1, processor.revision)
        }
        processor.setProfile(.guitar)
        XCTAssertEqual((processor.revision >> 2) & 3, PitchAlgorithm.mcleod.code)
    }
}
