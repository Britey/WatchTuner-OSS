import XCTest
import Dispatch
@testable import TunerDSP

private final class ProfileReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(PitchReading, UInt64)] = []
    func add(_ reading: PitchReading, _ revision: UInt64) { lock.lock(); defer { lock.unlock() }; values.append((reading, revision)) }
    func snapshot() -> [(PitchReading, UInt64)] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ProfileTests: XCTestCase {
    private let rate = 48000.0
    private func signal(hz: Double, gains: [Double], duration: Double = 0.18, stiffness: Double = 0,
                        noise: Double = 0, decay: Double = .infinity) -> [Float] {
        var seed: UInt64 = 982451653
        return (0..<Int(rate * duration)).map { i in
            let t = Double(i) / rate
            seed = seed &* 6364136223846793005 &+ 1
            var sample = noise * (Double(seed >> 32) / Double(UInt32.max) * 2 - 1)
            for h in gains.indices {
                let n = Double(h + 1)
                sample += gains[h] * sin(2 * .pi * hz * n * sqrt((1 + stiffness * n * n) / (1 + stiffness)) * t + 0.13 * n)
            }
            return Float(sample * exp(-t / decay))
        }
    }
    @discardableResult private func check(_ reading: PitchReading, hz: Double, tolerance: Double = 6,
                                          file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard case let .pitch(actual, _) = reading else { XCTFail("Expected \(hz), got \(reading)", file: file, line: line); return nil }
        XCTAssertLessThan(abs(1200 * log2(actual / hz)), tolerance, "\(hz) → \(actual)", file: file, line: line)
        return actual
    }
    func testDefaultPersistenceAndInvalidPreferenceFallback() throws {
        let name = "WatchTunerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TunerProfile.load(from: defaults), .vocals)
        for profile in TunerProfile.allCases { profile.save(to: defaults); XCTAssertEqual(TunerProfile.load(from: defaults), profile) }
        defaults.set("Unknown", forKey: TunerProfile.preferenceKey)
        XCTAssertEqual(TunerProfile.load(from: defaults), .vocals)
    }
    func testVocalLowThroughHighWithoutVoiceTypeExclusions() {
        for hz in [40.0, 55, 65.4, 82.4, 110, 146.8, 220, 330, 440, 659, 880, 1200, 1500, 1800] {
            check(PitchDetector(profile: .vocals).analyze(signal(hz: hz, gains: [0.18, 0.12, 0.07]), sampleRate: rate), hz: hz)
        }
    }
    func testLowProfileRangesKeepEnoughCyclesAtHighSampleRates() {
        for sampleRate in [16000.0, 48000, 96000, 192000] {
            for profile in [TunerProfile.vocals, .piano] {
                let hz = profile.minimumHz
                let input: [Float] = (0..<Int(sampleRate * 0.18)).map { i in
                    Float(0.2 * sin(2 * .pi * hz * Double(i) / sampleRate) + 0.1 * sin(4 * .pi * hz * Double(i) / sampleRate))
                }
                check(PitchDetector(profile: profile).analyze(input, sampleRate: sampleRate), hz: hz)
            }
        }
    }
    func testVocalFormantEnvelopesAndAbsentFirstHarmonic() {
        let detector = PitchDetector(profile: .vocals)
        for hz in [65.4, 110, 220, 440, 880] {
            for center in [600.0, 1400, 2600] {
                var gains = (1...16).map { h -> Double in
                    let frequency = hz * Double(h)
                    return (0.04 + 0.8 * exp(-pow((frequency - center) / 500, 2))) / pow(Double(h), 0.7)
                }
                let scale = 0.7 / gains.reduce(0, +)
                gains = gains.map { $0 * scale }
                check(detector.analyze(signal(hz: hz, gains: gains), sampleRate: rate), hz: hz)
            }
            check(detector.analyze(signal(hz: hz, gains: [0, 0.2, 0.16, 0.09, 0.04]), sampleRate: rate), hz: hz)
        }
        // Even-only partials contain no evidence of the intended lower root.
        check(detector.analyze(signal(hz: 110, gains: [0, 0.2, 0, 0.15, 0, 0.08]), sampleRate: rate), hz: 220)
    }
    func testVoicedBreathinessAndUnvoicedRejection() {
        let detector = PitchDetector(profile: .vocals)
        for hz in [82.4, 220, 440, 880] {
            check(detector.analyze(signal(hz: hz, gains: [0.14, 0.2, 0.12, 0.06], noise: 0.04), sampleRate: rate), hz: hz, tolerance: 10)
        }
        for seed in 1...20 {
            var state = UInt64(seed)
            let noise: [Float] = (0..<8640).map { _ in
                state = state &* 6364136223846793005 &+ 1
                return Float(Double(state >> 32) / Double(UInt32.max) * 0.6 - 0.3)
            }
            XCTAssertEqual(detector.analyze(noise, sampleRate: rate), .unclear)
        }
        var transient = [Float](repeating: 0, count: 8640)
        transient[transient.count - 400] = 0.8
        XCTAssertFalse({ if case .pitch = detector.analyze(transient, sampleRate: rate) { true } else { false } }())
        let ending = signal(hz: 220, gains: [0.3]) + [Float](repeating: 0, count: 1920)
        XCTAssertEqual(detector.analyze(ending, sampleRate: rate), .silence)
        var noiseState: UInt64 = 101
        let unvoicedEnding: [Float] = (0..<1920).map { _ in
            noiseState = noiseState &* 6364136223846793005 &+ 1
            return Float(0.15 + 0.15 * (Double(noiseState >> 32) / Double(UInt32.max) * 2 - 1))
        }
        let lowThenUnvoiced = signal(hz: 55, gains: [0.3]) + unvoicedEnding
        XCTAssertEqual(detector.analyze(lowThenUnvoiced, sampleRate: rate), .unclear)
    }
    func testVocalVibratoAmplitudeAndMeasuredWindowLag() {
        let detector = PitchDetector(profile: .vocals)
        let base = 220.0, depth = 40.0, length = Int(rate * 1.2)
        var phase = 0.0
        let input: [Float] = (0..<length).map { i in
            let hz = base * pow(2, depth * sin(2 * .pi * 5 * Double(i) / rate) / 1200)
            phase += 2 * .pi * hz / rate
            return Float(0.18 * sin(phase) + 0.12 * sin(2 * phase) + 0.06 * sin(3 * phase))
        }
        var tracker = PitchTracker(profile: .vocals)
        var observations: [(Double, Double)] = []
        for end in stride(from: 8640, through: length, by: 960) {
            let reading = tracker.accept(detector.analyze(Array(input[(end-8640)..<end]), sampleRate: rate))
            if case let .pitch(hz, _) = reading { observations.append((Double(end) / rate, 1200 * log2(hz / base))) }
        }
        XCTAssertGreaterThan(observations.count, 35)
        let span = (observations.map(\.1).max() ?? 0) - (observations.map(\.1).min() ?? 0)
        XCTAssertGreaterThan(span, depth * 1.8, "Vibrato must not be flattened")
        let lags = (0...80).map { lag -> (Int, Double) in
            let error = observations.reduce(0.0) { $0 + pow($1.1 - depth * sin(2 * .pi * 5 * ($1.0 - Double(lag) / 1000)), 2) }
            return (lag, error)
        }
        let best = lags.min { $0.1 < $1.1 }!
        XCTAssertLessThanOrEqual(best.0, 25)
        print("vocal_vibrato depth=40c measured_span=\(span)c synthetic_window_lag=\(best.0)ms reports=\(observations.count)")
    }
    func testVocalGlideTracksCurrentWindowWithoutFreezing() {
        let detector = PitchDetector(profile: .vocals)
        var phase = 0.0
        let length = Int(rate)
        let input: [Float] = (0..<length).map { i in
            let hz = 110 * pow(2, Double(i) / rate)
            phase += 2 * .pi * hz / rate
            return Float(0.2 * sin(phase) + 0.12 * sin(2 * phase))
        }
        var reports = 0
        for end in stride(from: 8640, through: length, by: 1920) {
            let centerHz = 110 * pow(2, Double(end) / rate - 0.02)
            if check(detector.analyze(Array(input[(end-8640)..<end]), sampleRate: rate), hz: centerHz, tolerance: 12) != nil { reports += 1 }
        }
        XCTAssertGreaterThan(reports, 15)
    }
    func testTemporalOctaveConfirmationPreservesRawCentsAndRealChanges() {
        var tracker = PitchTracker(profile: .vocals)
        func pitch(_ hz: Double) -> PitchReading { .pitch(hz: hz, confidence: 0.99) }
        XCTAssertEqual(tracker.accept(pitch(220)), .unclear)
        XCTAssertEqual(tracker.accept(pitch(220.3)), pitch(220.3))
        for hz in [219.4, 222.0, 225.0, 230.0, 330.0] { XCTAssertEqual(tracker.accept(pitch(hz)), pitch(hz)) }
        XCTAssertEqual(tracker.accept(pitch(660)), .unclear)
        XCTAssertEqual(tracker.accept(pitch(660.4)), pitch(660.4))
        XCTAssertEqual(tracker.accept(.silence), .silence)
        XCTAssertEqual(tracker.accept(pitch(660.4)), .unclear)
        tracker.reset()
        XCTAssertEqual(tracker.accept(pitch(110)), .unclear)
    }
    func testPianoFirstPartialWeakRootStiffnessAndDecay() {
        let detector = PitchDetector(profile: .piano)
        for hz in [27.5, 55, 110, 220, 440, 880, 1760, 3520, 4186] {
            for stiffness in [0.0, 0.0002, 0.0005] {
                let gains = (1...8).map { h in hz * Double(h) * sqrt(1 + stiffness * Double(h*h)) < rate * 0.45 ? 0.25 / Double(h) : 0 }
                check(detector.analyze(signal(hz: hz, gains: gains, stiffness: stiffness, decay: 0.4), sampleRate: rate), hz: hz, tolerance: 6)
            }
        }
        for hz in [55.0, 110, 440] {
            check(detector.analyze(signal(hz: hz, gains: [0.02, 0.25, 0.14, 0.08], stiffness: 0.0005), sampleRate: rate), hz: hz, tolerance: 6)
        }
        XCTAssertEqual(detector.analyze([Float](repeating: 0, count: 8640), sampleRate: rate), .silence)
    }
    func testPianoAttackRejectsAndRecoversAfterOnset() {
        let detector = PitchDetector(profile: .piano)
        var state: UInt64 = 73
        let attack: [Float] = (0..<8640).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) * 0.8 - 0.4)
        }
        XCTAssertEqual(detector.analyze(attack, sampleRate: rate), .unclear)
        check(detector.analyze(signal(hz: 261.626, gains: [0.2, 0.15, 0.08], decay: 0.2), sampleRate: rate), hz: 261.626)
    }
    func testProfileSwitchDropsPendingAnalysisAndRequiresFreshFrames() {
        let capture = DispatchQueue(label: "profile.test.capture"), analysis = DispatchQueue(label: "profile.test.analysis")
        let processor = PitchCaptureProcessor(profile: .guitar, algorithm: .current, queue: capture, analysisQueue: analysis)
        let reports = ProfileReports(), hold = DispatchSemaphore(value: 0)
        analysis.async { hold.wait() }
        let input = signal(hz: 220, gains: [0.3])
        processor.consumeVersioned(sampleRate: rate, sampleTime: 0, copySamples: { input }, report: reports.add)
        capture.sync {}
        let old = processor.revision
        processor.setProfile(.vocals)
        processor.setProfile(.guitar)
        XCTAssertNotEqual(old, processor.revision, "A → B → A must invalidate old UI callbacks too")
        hold.signal(); analysis.sync {}; capture.sync {}
        XCTAssertTrue(reports.snapshot().isEmpty)
        processor.setProfile(.piano)
        for block in 0..<12 {
            let position = block * 2048
            let buffer: [Float] = (position..<position+2048).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }
            processor.consumeVersioned(sampleRate: rate, sampleTime: Int64(position), copySamples: { buffer }, report: reports.add)
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        XCTAssertTrue(reports.snapshot().contains { if case .pitch = $0.0 { true } else { false } })
        XCTAssertTrue(reports.snapshot().allSatisfy { $0.1 == processor.revision })
    }
    func testUnknownUndersizedTimingFailsClosedInEveryProfile() {
        for profile in TunerProfile.allCases {
            let capture = DispatchQueue(label: "unknown.\(profile).capture")
            let analysis = DispatchQueue(label: "unknown.\(profile).analysis")
            let processor = PitchCaptureProcessor(profile: profile, algorithm: .current, queue: capture, analysisQueue: analysis)
            let reports = ProfileReports()
            for _ in 0..<12 {
                let buffer = signal(hz: 220, gains: [0.3], duration: 1024 / rate)
                processor.consumeVersioned(sampleRate: rate, sampleTime: nil, copySamples: { buffer }, report: reports.add)
                capture.sync {}; analysis.sync {}; capture.sync {}
            }
            XCTAssertTrue(reports.snapshot().allSatisfy { $0.0 == .unclear })
            XCTAssertEqual(reports.snapshot().count, 12)
            // Full unknown-timestamp buffers are independently analyzable. No
            // samples from different buffers are joined to create a period.
            let complete = signal(hz: 220, gains: [0.3])
            for _ in 0..<2 {
                processor.consumeVersioned(sampleRate: rate, sampleTime: nil, copySamples: { complete }, report: reports.add)
                capture.sync {}; analysis.sync {}; capture.sync {}
            }
            check(reports.snapshot().last!.0, hz: 220)
        }
    }
    func testOverlappingFramesRemainContiguousAndUnknownTimesNeverOverlap() {
        var frames = ContiguousPitchFrames(overlapping: true)
        var ends: [Int] = []
        for block in 0..<10 {
            let start = block * 2048, end = start + 2048
            if let frame = frames.append((start..<end).map(Float.init), sampleRate: rate, sampleTime: Int64(start)).samples {
                XCTAssertEqual(frame, ((end-8640)..<end).map(Float.init)); ends.append(end)
            }
        }
        XCTAssertEqual(ends.count, 6)
        for _ in 0..<10 { XCTAssertNil(frames.append([Float](repeating: 0.1, count: 2048), sampleRate: rate, sampleTime: nil).samples) }
    }
}
