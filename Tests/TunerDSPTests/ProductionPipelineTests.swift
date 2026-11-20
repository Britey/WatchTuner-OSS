import XCTest
import Dispatch
import AVFAudio
@testable import TunerDSP

private final class ProductionReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, PitchReading)] = []
    func append(_ time: Double, _ reading: PitchReading) {
        lock.lock(); defer { lock.unlock() }; values.append((time, reading))
    }
    func snapshot() -> [(Double, PitchReading)] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

/// App-selected configuration -> actual PCM copy/capture worker -> tracker -> display.
/// No AVAudioEngine, microphone, speaker or wall-clock performance claim.
/// Bright-formant regressions remain strict across candidate test builds.
final class ProductionPipelineTests: XCTestCase {
    private let rate = 48000.0

    @MainActor
    private func replay(_ input: [Float], profile: TunerProfile, block: Int = 4800) -> [(Double, PitchReading, PitchReading)] {
        let capture = DispatchQueue(label: "production.regression.capture")
        let analysis = DispatchQueue(label: "production.regression.analysis")
        let processor = PitchCaptureProcessor(configuration: .production(profile: profile), queue: capture, analysisQueue: analysis)
        let reports = ProductionReports()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        for start in stride(from: 0, through: input.count - block, by: block) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
            buffer.frameLength = AVAudioFrameCount(block)
            for i in 0..<block { buffer.floatChannelData![0][i] = input[start+i] }
            let time = Double(start + block) / rate
            processor.consumeVersioned(sampleRate: buffer.format.sampleRate, sampleTime: Int64(start), copySamples: {
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }) { reading, revision in
                guard processor.revision == revision else { return }
                reports.append(time, reading)
            }
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        var display = VocalDisplaySmoother()
        return reports.snapshot().map { time, raw in
            (time, raw, display.accept(raw, profile: profile, at: time))
        }
    }

    // Fixed formant envelope at the generating base with phase-integrated vibrato.
    // This synthetic signal does not model microphone or room acoustics.
    private func bright(_ base: Double, depth: Double) -> [Float] {
        let gains = (1...16).map { harmonic -> Double in
            let f = base * Double(harmonic)
            return (0.02 + exp(-pow((f-700)/100, 2)) + 0.7*exp(-pow((f-1200)/150, 2))
                    + 0.4*exp(-pow((f-2500)/250, 2))) / pow(Double(harmonic), 0.9)
        }
        let scale = 0.7 / gains.reduce(0, +)
        var phase = 0.0, samples: [Float] = []
        for index in 0..<Int(rate * 1.6) {
            let hz = base * pow(2, depth * sin(2 * .pi * 5.5 * Double(index)/rate) / 1200)
            phase += 2 * .pi * hz/rate
            var value = 0.0
            for h in 1...16 { value += scale * gains[h-1] * sin(Double(h)*phase + 0.37*Double(h)) }
            samples.append(Float(value))
        }
        return samples
    }

    private func expectRoot(_ readings: [PitchReading], base: Double, depth: Double, minimumRecall: Double,
                            context: String, file: StaticString = #filePath, line: UInt = #line) {
        let cents = readings.compactMap { reading -> Double? in
            if case let .pitch(hz, _) = reading { return 1200 * log2(hz/base) }; return nil
        }
        XCTAssertFalse(readings.isEmpty, context, file: file, line: line)
        let recall = Double(cents.count) / Double(max(1, readings.count))
        let wrong = cents.filter { abs($0) > depth + 100 }.count
        print("production_pipeline \(context) voiced=\(cents.count)/\(readings.count) grossWrong=\(wrong)")
        XCTAssertGreaterThanOrEqual(recall, minimumRecall, context + " voiced recall", file: file, line: line)
        XCTAssertEqual(wrong, 0, context + " wrong harmonic/octave", file: file, line: line)
    }

    func testProductionConfigurationAndAtomicProfileChanges() {
        let processor = PitchCaptureProcessor(configuration: .production(profile: .vocals))
        var revision = processor.revision
        for profile in TunerProfile.allCases {
            let settings = PitchConfiguration.production(profile: profile)
            // The production factory selects Pitchy for every profile.
            XCTAssertEqual(settings.algorithm, .mcleod)
            processor.setConfiguration(settings)
            XCTAssertNotEqual(revision, processor.revision)
            XCTAssertEqual(processor.revision & 15, settings.code)
            revision = processor.revision
        }
    }

    func testProductionProfileChangeRejectsQueuedPreviousConfiguration() {
        let capture = DispatchQueue(label: "production.change.capture")
        let analysis = DispatchQueue(label: "production.change.analysis")
        let processor = PitchCaptureProcessor(configuration: .production(profile: .guitar), queue: capture, analysisQueue: analysis)
        let reports = ProductionReports(), hold = DispatchSemaphore(value: 0)
        let block: [Float] = (0..<8640).map { Float(0.12*sin(2 * .pi * 440*Double($0)/rate)) }
        analysis.async { hold.wait() }
        processor.consumeVersioned(sampleRate: rate, sampleTime: 0, copySamples: { block }) { reading, _ in reports.append(0, reading) }
        capture.sync {}
        let old = processor.revision
        processor.setConfiguration(.production(profile: .piano))
        XCTAssertNotEqual(processor.revision, old)
        hold.signal(); analysis.sync {}; capture.sync {}
        XCTAssertTrue(reports.snapshot().isEmpty)
        for index in 1...3 {
            processor.consumeVersioned(sampleRate: rate, sampleTime: Int64(index*8640), copySamples: { block }) { reading, revision in
                guard processor.revision == revision else { return }
                reports.append(Double(index), reading)
            }
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        XCTAssertTrue(reports.snapshot().contains { if case .pitch = $0.1 { true } else { false } })
    }

    @MainActor func testQuietToneThroughEveryProductionProfile() async {
        for profile in TunerProfile.allCases {
            for amplitude in [0.2, 0.00003] {
                let input = (0..<76800).map { Float(amplitude*sin(2 * .pi * 440*Double($0)/rate)) }
                let reports = replay(input, profile: profile).filter { $0.0 > 0.3 }
                expectRoot(reports.map(\.1), base: 440, depth: 0, minimumRecall: 1, context: "\(profile) raw amp=\(amplitude)")
                expectRoot(reports.map(\.2), base: 440, depth: 0, minimumRecall: 1, context: "\(profile) display amp=\(amplitude)")
            }
        }
    }

    @MainActor func testProductionSilenceNoiseAndOverloadDoNotDisplayPitch() async {
        var state: UInt64 = 101
        let noise: [Float] = (0..<76800).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(0.03 * (Double(state >> 32)/Double(UInt32.max)*2 - 1))
        }
        for profile in TunerProfile.allCases {
            for input in [[Float](repeating: 0, count: 76800), noise,
                          (0..<76800).map({ $0.isMultiple(of: 2) ? Float(1) : Float(-1) })] {
                let reports = replay(input, profile: profile).filter { $0.0 > 0.3 }
                XCTAssertFalse(reports.isEmpty)
                XCTAssertFalse(reports.contains { if case .pitch = $0.1 { true } else { false } })
                XCTAssertFalse(reports.contains { if case .pitch = $0.2 { true } else { false } })
            }
        }
    }

    @MainActor func testProductionDisplayClearsAfterVoicedEnding() async {
        for profile in TunerProfile.allCases {
            let input: [Float] = (0..<57600).map { i in
                i < 28800 ? Float(0.12*sin(2 * .pi * 440*Double(i)/rate)) : 0
            }
            let reports = replay(input, profile: profile)
            XCTAssertTrue(reports.contains { if case .pitch = $0.2 { $0.0 < 0.6 } else { false } })
            let ending = reports.filter { $0.0 >= 0.8 }
            XCTAssertFalse(ending.isEmpty)
            XCTAssertFalse(ending.contains { if case .pitch = $0.2 { true } else { false } })
        }
    }

    @MainActor func testProductionPianoAndGuitarDecayingQuietSources() async {
        // A bounded low-noise regression, not a claim to cover real room acoustics.
        for profile in [TunerProfile.piano, .guitar] {
            for base in [110.0, 440] {
                for amplitude in [0.1, 0.00003] {
                    var state: UInt64 = 193939
                    let detunings = profile == .piano ? [-2.5, 0, 2.5] : [0.0]
                    let input: [Float] = (0..<76800).map { index in
                        let t = Double(index)/rate + 0.2
                        state = state &* 6364136223846793005 &+ 1
                        var value = 0.015*(Double(state >> 32)/Double(UInt32.max)*2 - 1)
                        for cents in detunings {
                            for h in 1...8 {
                                let n = Double(h)
                                let hz = base*pow(2, cents/1200)*n*sqrt((1 + 0.0002*n*n)/1.0002)
                                let phase = 2 * .pi * hz*t + 0.31*n + cents
                                value += exp(-t/(0.8/sqrt(n)))/(n*Double(detunings.count))
                                    * (sin(phase) + 0.35*sin(phase - 2 * .pi * hz*0.013))
                            }
                        }
                        return Float(amplitude*value)
                    }
                    let reports = replay(input, profile: profile).filter { $0.0 > 0.3 && $0.0 < 0.9 }
                    expectRoot(reports.map(\.2), base: base, depth: 0, minimumRecall: 0.95,
                               context: "decay \(profile) \(base)Hz amp=\(amplitude)")
                    for (_, _, reading) in reports {
                        if case let .pitch(hz, _) = reading { XCTAssertLessThan(abs(1200*log2(hz/base)), 8) }
                    }
                }
            }
        }
    }

    @MainActor func testBrightLowVocalRecallAtDiagnosticAndSupportedTapCadences() async {
        for (base, depth) in [(82.4, 40.0), (147.0, 100.0)] {
            let input = bright(base, depth: depth)
            for block in [1024, 4800] {
                let reports = replay(input, profile: .vocals, block: block).filter { $0.0 > 0.3 }
                XCTAssertEqual(reports.count, block == 1024 ? 61 : 13)
                expectRoot(reports.map(\.1), base: base, depth: depth, minimumRecall: 0.95, context: "bright \(base)Hz block=\(block) raw")
                expectRoot(reports.map(\.2), base: base, depth: depth, minimumRecall: 0.95, context: "bright \(base)Hz block=\(block) display")
            }
        }
    }

    @MainActor func testBrightStationaryVocalKeepsRootInsteadOfSecondHarmonic() async {
        for base in [300.0, 315, 330] {
            let input = bright(base, depth: 0)
            for block in [1024, 4800] {
                let reports = replay(input, profile: .vocals, block: block).filter { $0.0 > 0.3 }
                expectRoot(reports.map(\.1), base: base, depth: 0, minimumRecall: 0.95, context: "stationary \(base)Hz block=\(block) raw")
                expectRoot(reports.map(\.2), base: base, depth: 0, minimumRecall: 0.95, context: "stationary \(base)Hz block=\(block) display")
            }
        }
    }

    @MainActor func testBrightUpperVocalVibratoAvoidsWrongHarmonics() async {
        for base in [220.0, 440] {
            let input = bright(base, depth: 100)
            for block in [1024, 4800] {
                let reports = replay(input, profile: .vocals, block: block).filter { $0.0 > 0.3 }
                expectRoot(reports.map(\.1), base: base, depth: 100, minimumRecall: 0.95, context: "vibrato \(base)Hz block=\(block) raw")
                expectRoot(reports.map(\.2), base: base, depth: 100, minimumRecall: 0.95, context: "vibrato \(base)Hz block=\(block) display")
            }
        }
    }
}
