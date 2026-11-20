import XCTest
import Dispatch
@testable import TunerDSP

private final class TimedReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, PitchReading)] = []
    func add(time: Double, reading: PitchReading) { lock.lock(); defer { lock.unlock() }; values.append((time, reading)) }
    func snapshot() -> [(Double, PitchReading)] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Historical harmonic-detector regressions; production-path coverage is separate.
final class VocalPipelineTests: XCTestCase {
    private let rate = 48000.0
    private func run(_ input: [Float], blockSize: Int = 1024, validTimestamps: Bool = true) -> [(Double, PitchReading)] {
        let capture = DispatchQueue(label: "vocal.pipeline.capture"), analysis = DispatchQueue(label: "vocal.pipeline.analysis")
        let processor = PitchCaptureProcessor(profile: .vocals, algorithm: .current, queue: capture, analysisQueue: analysis)
        let readings = TimedReadings()
        for start in stride(from: 0, through: input.count - blockSize, by: blockSize) {
            let block = Array(input[start..<start+blockSize]), time = Double(start+blockSize) / rate
            processor.consumeVersioned(sampleRate: rate, sampleTime: validTimestamps ? Int64(start) : nil, copySamples: { block }) { reading, _ in readings.add(time: time, reading: reading) }
            capture.sync {}; analysis.sync {}; capture.sync {}
        }
        return readings.snapshot()
    }
    func testPipelineVibratoRecallCentsAmplitudeAndLagAcrossRegisters() {
        for base in [82.4, 220, 880] {
            for speed in [4.0, 6] {
                let depth = 40.0, duration = 1.6
                var phase = 0.0
                let input: [Float] = (0..<Int(rate * duration)).map { i in
                    let hz = base * pow(2, depth * sin(2 * .pi * speed * Double(i) / rate) / 1200)
                    phase += 2 * .pi * hz / rate
                    return Float(0.14 * sin(phase) + 0.2 * sin(2 * phase) + 0.13 * sin(3 * phase) + 0.06 * sin(5 * phase))
                }
                let reports = run(input).filter { $0.0 >= 0.3 }
                let voiced = reports.compactMap { time, reading -> (Double, Double)? in
                    if case let .pitch(hz, _) = reading { return (time, 1200 * log2(hz / base)) }; return nil
                }
                XCTAssertGreaterThanOrEqual(Double(voiced.count) / Double(reports.count), 0.99, "base=\(base) rate=\(speed)")
                XCTAssertTrue(voiced.allSatisfy { abs($0.1) < 100 }, "No octave errors")
                guard voiced.count > 2 else { continue }
                let span = voiced.map(\.1).max()! - voiced.map(\.1).min()!
                XCTAssertGreaterThan(span / (2 * depth), 0.85)
                let best = (0...90).map { lag -> (Int, Double) in
                    (lag, voiced.reduce(0) { $0 + pow($1.1 - depth * sin(2 * .pi * speed * ($1.0 - Double(lag) / 1000)), 2) })
                }.min { $0.1 < $1.1 }!
                let errors = voiced.map { abs($0.1 - depth * sin(2 * .pi * speed * ($0.0 - Double(best.0) / 1000))) }.sorted()
                let instantaneous = voiced.map { abs($0.1 - depth * sin(2 * .pi * speed * $0.0)) }.sorted()
                XCTAssertLessThan(instantaneous[Int(Double(instantaneous.count-1) * 0.95)], 55)
                XCTAssertLessThanOrEqual(best.0, 45)
                XCTAssertLessThan(errors[Int(Double(errors.count-1) * 0.95)], 6)
                print("vocal_pipeline base=\(base) vibrato=\(speed)Hz recall=\(Double(voiced.count)/Double(reports.count)) amplitude_ratio=\(span/(2*depth)) window_lag_ms=\(best.0) median_cents=\(errors[errors.count/2]) p95_cents=\(errors[Int(Double(errors.count-1)*0.95)]) instantaneous_p95_cents=\(instantaneous[Int(Double(instantaneous.count-1)*0.95)]) octave_errors=0")
            }
        }
    }
    func testVibratoDoesNotDropOutAtShortWindowCycleBoundary() {
        for base in [95.0, 98, 99, 100, 101, 102, 104, 110] {
            for speed in [4.0, 6] {
                var phase = 0.0
                let input: [Float] = (0..<76800).map { i in
                    let hz = base * pow(2, 40 * sin(2 * .pi * speed * Double(i) / rate) / 1200)
                    phase += 2 * .pi * hz / rate
                    return Float(0.14 * sin(phase) + 0.2 * sin(2 * phase) + 0.13 * sin(3 * phase) + 0.06 * sin(5 * phase))
                }
                let reports = run(input).filter { $0.0 > 0.3 }
                let cents = reports.compactMap { _, reading -> Double? in
                    if case let .pitch(hz, _) = reading { return 1200 * log2(hz / base) }; return nil
                }
                XCTAssertEqual(reports.count, 61)
                XCTAssertEqual(cents.count, reports.count, "Clean vibrato dropout at base=\(base), rate=\(speed)")
                XCTAssertTrue(cents.allSatisfy { abs($0) < 100 }, "No octave errors")
                let amplitude = ((cents.max() ?? 0) - (cents.min() ?? 0)) / 80
                XCTAssertGreaterThan(amplitude, 0.6)
                print("vocal_boundary base=\(base) vibrato=\(speed)Hz voiced=\(cents.count)/\(reports.count) amplitude_ratio=\(amplitude)")
            }
        }
    }
    func testLongerWindowRecoveryDoesNotHoldThroughSilentOrUnvoicedEndings() {
        for base in [98.0, 100, 102, 110, 220, 440] {
            for noisy in [false, true] {
                var phase = 0.0, state: UInt64 = 101
                let input: [Float] = (0..<38400).map { i in
                    let time = Double(i) / rate
                    phase += 2 * .pi * base / rate
                    if time < 0.6 { return Float(0.2 * sin(phase) + 0.12 * sin(2 * phase)) }
                    if !noisy { return 0 }
                    state = state &* 6364136223846793005 &+ 1
                    return Float(0.15 + 0.15 * (Double(state >> 32) / Double(UInt32.max) * 2 - 1))
                }
                let reports = run(input)
                XCTAssertTrue(reports.contains { if case .pitch = $0.1 { $0.0 < 0.6 } else { false } })
                let endings = reports.filter { $0.0 >= 0.67 }
                XCTAssertFalse(endings.isEmpty)
                XCTAssertTrue(endings.allSatisfy { if case .pitch = $0.1 { false } else { true } }, "Stale fallback at \(base), noisy=\(noisy)")
            }
        }
    }
    func testBrightFormantVibratoRecoveryRetainsRootIdentity() {
        // Explicit Swift family with phase-integrated vibrato. The two priority
        // formerly failing traces must recover fully without octave guesses.
        for (base, depth) in [(82.4, 20.0), (82.4, 40.0), (147.0, 20.0), (147.0, 100.0)] {
            var gains = (1...16).map { h -> Double in
                let f = base * Double(h)
                let envelope = 0.02 + exp(-pow((f-700)/100, 2)) + 0.7 * exp(-pow((f-1200)/150, 2)) + 0.4 * exp(-pow((f-2500)/250, 2))
                return envelope / pow(Double(h), 0.9)
            }
            let scale = 0.7 / gains.reduce(0, +)
            gains = gains.map { $0 * scale }
            var phase = 0.0
            let input: [Float] = (0..<76800).map { i in
                let hz = base * pow(2, depth * sin(2 * .pi * 5.5 * Double(i) / rate) / 1200)
                phase += 2 * .pi * hz / rate
                return Float(gains.indices.reduce(0.0) { $0 + gains[$1] * sin(Double($1+1) * phase + 0.37 * Double($1+1)) })
            }
            let reports = run(input).filter { $0.0 > 0.3 }
            let cents = reports.compactMap { _, reading -> Double? in
                if case let .pitch(hz, _) = reading { return 1200 * log2(hz / base) }; return nil
            }
            XCTAssertTrue(cents.allSatisfy { abs($0) <= depth + 100 }, "No gross note/octave errors")
            XCTAssertEqual(reports.count, 61)
            XCTAssertEqual(cents.count, reports.count)
            let timed = reports.compactMap { time, reading -> (Double, Double)? in
                if case let .pitch(hz, _) = reading { return (time, 1200 * log2(hz / base)) }; return nil
            }
            let best = (0...90).map { lag -> (Int, Double) in
                (lag, timed.reduce(0) { $0 + pow($1.1 - depth * sin(2 * .pi * 5.5 * ($1.0 - Double(lag) / 1000)), 2) })
            }.min { $0.1 < $1.1 }!
            let errors = timed.map { abs($0.1 - depth * sin(2 * .pi * 5.5 * ($0.0 - Double(best.0) / 1000))) }.sorted()
            let instantaneous = timed.map { abs($0.1 - depth * sin(2 * .pi * 5.5 * $0.0)) }.sorted()
            let amplitude = ((cents.max() ?? 0) - (cents.min() ?? 0)) / (2 * depth)
            XCTAssertGreaterThan(amplitude, 0.85)
            XCTAssertLessThanOrEqual(best.0, 45)
            XCTAssertLessThan(errors[Int(Double(errors.count-1)*0.95)], 30)
            XCTAssertLessThan(instantaneous[Int(Double(instantaneous.count-1)*0.95)], 70)
            print("bright_formant_stress base=\(base) depth=\(depth)c speed=5.5Hz voiced=\(cents.count)/\(reports.count) rejected=\(reports.count-cents.count) amplitude_ratio=\(amplitude) fitted_lag_ms=\(best.0) aligned_p95_cents=\(errors[Int(Double(errors.count-1)*0.95)]) instantaneous_p95_cents=\(instantaneous[Int(Double(instantaneous.count-1)*0.95)])")
        }
    }
    func testVocalRecoveryRejectsUnvoicedNoiseAndDoesNotInventHumSubharmonics() {
        let detector = PitchDetector(profile: .vocals)
        var state: UInt64 = 32452843
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state >> 32) / Double(UInt32.max) * 2 - 1
        }
        // White noise, leaky low-pass noise and sparse transients, with DC offsets.
        // These are deterministic empirical rejection probes, not all possible noise.
        for kind in 0..<3 {
            for _ in 0..<64 {
                var low = 0.0
                let input: [Float] = (0..<8640).map { i in
                    let white = random()
                    low = 0.75 * low + 0.25 * white
                    let value = kind == 0 ? 0.18 * white : kind == 1 ? 0.35 * low : (i % 401 == 0 ? 0.7 * white : 0)
                    return Float(value + 0.1)
                }
                XCTAssertFalse({ if case .pitch = detector.analyze(input, sampleRate: rate) { true } else { false } }(), "noise family=\(kind)")
            }
        }
        var voiced = 0, ambiguous = 0
        for base in [82.4, 102, 147, 220] {
            for extra in [50.0, 60, base / 2, base / 3] {
                for gain in [0.006, 0.015] {
                    var phase = 0.0
                    let input: [Float] = (0..<8640).map { i in
                        let hz = base * pow(2, 40 * sin(2 * .pi * 5.5 * Double(i) / rate) / 1200)
                        phase += 2 * .pi * hz / rate
                        return Float(0.18 * sin(phase) + 0.2 * sin(2 * phase) + 0.13 * sin(3 * phase)
                            + gain * sin(2 * .pi * extra * Double(i) / rate + 0.7))
                    }
                    if case let .pitch(hz, _) = detector.analyze(input, sampleRate: rate) {
                        voiced += 1
                        if base == 220 && extra == 110 && gain == 0.015 {
                            // Baseline ce9 also selects the observed weak lower root.
                            // Preserve the declared source-ambiguity policy explicitly.
                            ambiguous += 1
                            XCTAssertLessThan(abs(1200 * log2(hz / 110)), 80)
                        } else {
                            XCTAssertLessThan(abs(1200 * log2(hz / base)), 80, "Invented lower root: \(base) + \(extra) @ \(gain) → \(hz)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(ambiguous, 1)
        XCTAssertGreaterThanOrEqual(voiced, 24, "Do not pass by rejecting every contaminated voice")
        print("vocal_recovery empirical_noise=192 rejected=192 hum_and_weak_lower=32 voiced=\(voiced) known_weak_root_ambiguity=\(ambiguous)")
    }

    func testBrightRecoveryWithHumAndWeakLowerInterference() {
        for (base, depth) in [(82.4, 40.0), (147.0, 100.0)] {
            var gains = (1...16).map { h -> Double in
                let f = base * Double(h)
                return (0.02 + exp(-pow((f-700)/100, 2)) + 0.7 * exp(-pow((f-1200)/150, 2)) + 0.4 * exp(-pow((f-2500)/250, 2))) / pow(Double(h), 0.9)
            }
            let scale = 0.7 / gains.reduce(0, +); gains = gains.map { $0 * scale }
            for extra in [50.0, 60, base / 2] {
                var phase = 0.0
                let input: [Float] = (0..<76800).map { i in
                    let hz = base * pow(2, depth * sin(2 * .pi * 5.5 * Double(i) / rate) / 1200)
                    phase += 2 * .pi * hz / rate
                    let voice = gains.indices.reduce(0.0) { $0 + gains[$1] * sin(Double($1+1) * phase + 0.37 * Double($1+1)) }
                    return Float(voice + 0.006 * sin(2 * .pi * extra * Double(i) / rate + 0.7))
                }
                let reports = run(input).filter { $0.0 > 0.3 }
                let cents = reports.compactMap { _, reading -> Double? in
                    if case let .pitch(hz, _) = reading { return 1200 * log2(hz / base) }; return nil
                }
                XCTAssertTrue(cents.allSatisfy { abs($0) < depth + 100 }, "New recovery root error: \(base) + \(extra)")
                XCTAssertEqual(cents.count, reports.count)
                print("bright_recovery_interference base=\(base) depth=\(depth) extra=\(extra) gain=0.006 voiced=\(cents.count)/\(reports.count)")
            }
        }
    }

    func testDocumentedTapCadencesMeasureSeparateAcquisition() {
        let input: [Float] = (0..<57600).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }
        for (size, valid, expected) in [(4800, true, 0.3), (8640, false, 0.36)] {
            let reports = run(input, blockSize: size, validTimestamps: valid)
            let acquisition = reports.first { if case .pitch = $0.1 { true } else { false } }?.0 ?? .infinity
            XCTAssertEqual(acquisition, expected, accuracy: 0.00001)
            for (_, reading) in reports where reading != .unclear {
                guard case let .pitch(hz, _) = reading else { return XCTFail("Unexpected result \(reading)") }
                XCTAssertLessThan(abs(1200 * log2(hz / 220)), 1)
            }
            print("tap_cadence samples=\(size) timestamp_valid=\(valid) acquisition_ms=\(acquisition*1000) excludes_hardware_delay=true")
        }
    }

    func testPipelineAcquisitionReleaseAndTrueOctaveChange() {
        let duration = 1.4
        var phase = 0.0
        let input: [Float] = (0..<Int(rate * duration)).map { i in
            let time = Double(i) / rate
            let hz = time < 0.6 ? 220.0 : 440
            phase += 2 * .pi * hz / rate
            return time >= 1.1 ? 0 : Float(0.2 * sin(phase) + 0.1 * sin(2 * phase))
        }
        let reports = run(input)
        let acquisition = reports.first { if case .pitch = $0.1 { true } else { false } }?.0 ?? .infinity
        let octave = reports.first { if case let .pitch(hz, _) = $0.1 { $0.0 >= 0.6 && abs(1200 * log2(hz / 440)) < 10 } else { false } }?.0 ?? .infinity
        let release = reports.first { time, reading in
            guard time >= 1.1 else { return false }
            if case .pitch = reading { return false }; return true
        }?.0 ?? .infinity
        XCTAssertLessThanOrEqual(acquisition, 0.22)
        XCTAssertLessThanOrEqual(octave - 0.6, 0.08)
        XCTAssertLessThanOrEqual(release - 1.1, 0.04 + 1024 / rate)
        XCTAssertFalse(reports.contains { if case .pitch = $0.1 { $0.0 > 1.18 } else { false } })
        print("vocal_pipeline acquisition_ms=\(acquisition*1000) octave_change_ms=\((octave-0.6)*1000) release_ms=\((release-1.1)*1000)")
    }
    func testOffBinVowelSpectralHolesRandomPhasesAndReverberation() {
        let detector = PitchDetector(profile: .vocals)
        var seed: UInt64 = 32452843
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 32) / Double(UInt32.max) }
        var reports = 0, errors: [Double] = []
        for base in [65.4, 110, 220, 440, 880, 1500] {
            for cents in [5.0, 10, 25, 50] {
                let hz = base * pow(2, cents / 1200)
                let phases = (0..<12).map { _ in random() * 2 * .pi }
                var gains = (1...12).map { h -> Double in
                    let frequency = hz * Double(h)
                    return frequency < rate * 0.44 ? (0.02 + exp(-pow((frequency - 1600) / 700, 2))) / Double(h) : 0
                }
                gains[0] *= 0.1 // high-pass/weak H1
                gains[3] = 0 // a spectral hole, not an even-only comb
                let scale = 0.7 / gains.reduce(0, +)
                var input: [Float] = (0..<8640).map { i in
                    let phase = 2 * .pi * hz * Double(i) / rate
                    return Float(gains.indices.reduce(0.0) { $0 + gains[$1] * scale * sin(Double($1+1) * phase + phases[$1]) })
                }
                let dry = input
                for i in 733..<input.count { input[i] += dry[i-733] * 0.25 }
                if case let .pitch(actual, _) = detector.analyze(input, sampleRate: rate) {
                    let error = abs(1200 * log2(actual / hz)); errors.append(error); reports += 1
                    XCTAssertLessThan(error, 12, "\(hz) → \(actual)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(reports, 18)
        errors.sort()
        print("vowel_stress total=24 voiced=\(reports) rejected=\(24-reports) median_cents=\(errors.isEmpty ? -1 : errors[errors.count/2])")
    }
}
